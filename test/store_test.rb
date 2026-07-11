# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "sequel"

class StoreArticle
  include Hacienda::Attributes

  attributes :id, :body, :created_at, :updated_at
  attribute :title, default: ""
  attribute :metadata, default: -> { {} }
  attribute :lock_version, default: 0, cast: ->(value) { value.to_i }
end

class AttributesTest < Minitest::Test
  def test_declares_accessors_defaults_casts_and_full_attributes
    article = StoreArticle.new(title: "Hacienda", lock_version: "2")

    assert_equal "Hacienda", article.title
    assert_equal 2, article.lock_version
    assert_equal({}, article.metadata)
    assert_equal StoreArticle.attribute_definitions.keys, article.attributes.keys
  end

  def test_rejects_unknown_attributes
    error = assert_raises(ArgumentError) { StoreArticle.new(missing: true) }

    assert_includes error.message, ":missing"
  end

  def test_tracks_changed_attributes_separately_from_full_attributes
    article = StoreArticle.from_persistence(id: 1, title: "Before", metadata: {"tags" => []})

    article.title = "After"
    article.metadata["tags"] << "ruby"

    assert article.changed?
    assert_equal %i[title metadata], article.changed_attribute_names
    assert_equal({title: "After", metadata: {"tags" => ["ruby"]}}, article.changed_attributes)
    assert_equal ["Before", "After"], article.changes[:title]
    assert_equal "Before", article.attribute_was(:title)
    assert_equal 1, article.attributes[:id]
  end

  def test_from_persistence_returns_a_clean_persisted_record
    article = StoreArticle.from_persistence(id: 1, title: "Loaded")

    assert article.persisted?
    refute article.changed?
  end
end

class StoreTest < Minitest::Test
  def setup
    @database = Sequel.sqlite
    @database.create_table(:articles) do
      primary_key :id
      String :title, null: false
      String :body, null: false, default: "from the database"
      String :metadata, null: false, default: "{}"
      DateTime :created_at
      DateTime :updated_at
      Integer :lock_version, null: false, default: 0
    end
    @now = Time.utc(2026, 6, 28, 12, 0, 0)
    @store = Hacienda::Store.new(
      database: @database,
      table: :articles,
      record: StoreArticle,
      lock: :lock_version,
      coercions: {
        metadata: {
          load: ->(value) { value.to_s.empty? ? {} : JSON.parse(value) },
          dump: ->(value) { JSON.generate(value || {}) }
        }
      },
      clock: -> { @now }
    )
  end

  def teardown
    @database.disconnect
  end

  def test_insert_sets_store_owned_fields_and_refreshes_database_defaults
    article = StoreArticle.new(title: "A record", metadata: {"kind" => "example"})

    assert_same article, @store.save(article)

    assert article.persisted?
    refute article.changed?
    assert article.id
    assert_equal "from the database", article.body
    assert_equal @now.strftime("%F %T"), article.created_at.strftime("%F %T")
    assert_equal @now.strftime("%F %T"), article.updated_at.strftime("%F %T")
    assert_equal 0, article.lock_version
    assert_equal({"kind" => "example"}, article.metadata)
    assert_equal %({"kind":"example"}), @database[:articles].get(:metadata)
  end

  def test_custom_datasets_reuse_the_store_row_mapper
    first = @store.save(StoreArticle.new(title: "First"))
    second = @store.save(StoreArticle.new(title: "Second"))

    records = @store.all(@store.dataset.where(id: [first.id, second.id]).reverse_order(:id))
    one = @store.first(@store.dataset.where(title: "First"))
    loaded = @store.load(@store.dataset.where(title: "Second").first)

    assert_equal ["Second", "First"], records.map(&:title)
    assert_instance_of StoreArticle, one
    assert_equal "First", one.title
    refute one.changed?
    assert_equal "Second", loaded.title
    assert loaded.persisted?
  end

  def test_update_writes_only_changed_attributes
    article = @store.save(StoreArticle.new(title: "Before", body: "original"))
    @database[:articles].where(id: article.id).update(body: "changed elsewhere")

    article.title = "After"
    @store.save(article)

    row = @database[:articles].where(id: article.id).first
    assert_equal "After", row[:title]
    assert_equal "changed elsewhere", row[:body]
    assert_equal 1, row[:lock_version]
    refute article.changed?
  end

  def test_unchanged_persisted_records_are_a_no_op
    article = @store.save(StoreArticle.new(title: "Unchanged"))
    @database[:articles].where(id: article.id).update(updated_at: Time.utc(2020, 1, 1))

    @store.save(article)

    assert_equal Time.utc(2020, 1, 1), @database[:articles].where(id: article.id).get(:updated_at)
  end

  def test_dirty_state_is_only_cleared_after_transaction_commit
    article = @store.save(StoreArticle.new(title: "Before"))

    @database.transaction do
      article.title = "Rolled back"
      @store.save(article)
      assert article.changed?
      raise Sequel::Rollback
    end

    assert article.changed?
    assert_equal "Before", article.attribute_was(:title)
    assert_equal "Rolled back", article.title
    assert_equal "Before", @database[:articles].where(id: article.id).get(:title)
  end

  def test_rolled_back_insert_restores_the_primary_key_and_remains_dirty
    article = StoreArticle.new(title: "Rolled back")

    @database.transaction do
      @store.save(article)
      assert article.id
      refute article.persisted?
      raise Sequel::Rollback
    end

    assert_nil article.id
    refute article.persisted?
    assert article.changed?
    assert_equal 0, @database[:articles].count
  end

  def test_optimistic_locking_raises_stale_object
    article = @store.save(StoreArticle.new(title: "Original"))
    first = @store.find(article.id)
    stale = @store.find(article.id)

    first.title = "First writer"
    @store.save(first)
    stale.title = "Second writer"

    error = assert_raises(Hacienda::Store::StaleObject) { @store.save(stale) }

    assert_includes error.message, "StoreArticle"
    assert_equal "First writer", @store.find(article.id).title
  end

  def test_refresh_is_explicit_after_updates
    article = @store.save(StoreArticle.new(title: "In memory"))
    @database[:articles].where(id: article.id).update(title: "In database")

    assert_equal "In memory", article.title
    assert_same article, @store.refresh(article)
    assert_equal "In database", article.title
    refute article.changed?
  end

  def test_store_has_no_identity_map
    article = @store.save(StoreArticle.new(title: "Independent"))

    refute_same @store.find(article.id), @store.find(article.id)
  end
end
