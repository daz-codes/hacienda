# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "sequel"

class RepositoryArticle
  include Lunula::Attributes

  attributes :uuid, :title, :metadata, :created_at, :updated_at
  attribute :lock_version, default: 0
end

class RepositoryTest < Minitest::Test
  def setup
    @database = Sequel.sqlite
    @database.create_table(:articles) do
      primary_key :uuid
      String :title, null: false
      String :metadata, null: false, default: "{}"
      DateTime :created_at
      DateTime :updated_at
      Integer :lock_version, null: false, default: 0
    end

    database = @database
    @repository = Module.new do
      extend Lunula::Repository

      store(
        database: database,
        table: :articles,
        record: RepositoryArticle,
        primary_key: :uuid,
        lock: :lock_version,
        coercions: {
          metadata: {
            load: ->(value) { JSON.parse(value) },
            dump: ->(value) { JSON.generate(value) }
          }
        }
      )

      def all(scope = dataset)
        super(scope.order(:title))
      end

      def titled(title)
        all(dataset.where(title: title))
      end

      def row_count
        database[:articles].count
      end
    end
  end

  def teardown
    @database.disconnect
  end

  def test_exposes_explicit_persistence_operations_without_a_store_constant
    second = RepositoryArticle.new(title: "Second", metadata: {"position" => 2})
    first = RepositoryArticle.new(title: "First", metadata: {"position" => 1})

    assert_same second, @repository.save(second)
    @repository.save(first)

    assert second.created_at
    assert second.updated_at
    assert_equal %w[First Second], @repository.all.map(&:title)
    assert_equal ["Second"], @repository.titled("Second").map(&:title)
    assert_equal "First", @repository.first(@repository.dataset.order(:title)).title
    assert_equal "First", @repository.find(first.uuid).title
    assert_equal 2, @repository.row_count
    refute @repository.const_defined?(:STORE, false)
    refute @repository.respond_to?(:database)
  end

  def test_find_by_and_find_by_bang_have_explicit_missing_record_semantics
    article = @repository.save(RepositoryArticle.new(title: "First", metadata: {}))

    assert_equal article.uuid, @repository.find_by(title: "First").uuid
    assert_nil @repository.find_by(title: "Missing")
    assert_raises(Lunula::NotFound) { @repository.find("missing") }
    assert_raises(Lunula::NotFound) { @repository.find_by!(title: "Missing") }
    assert_raises(ArgumentError) { @repository.find_by }
    assert_raises(ArgumentError) { @repository.find_by! }
  end

  def test_load_refresh_delete_and_store_options_are_preserved
    article = @repository.save(RepositoryArticle.new(title: "Before", metadata: {"tag" => "ruby"}))
    loaded = @repository.load(@repository.dataset.where(uuid: article.uuid).first)

    assert_equal({"tag" => "ruby"}, loaded.metadata)

    @repository.dataset.where(uuid: article.uuid).update(title: "After")
    assert_same article, @repository.refresh(article)
    assert_equal "After", article.title
    assert_same article, @repository.delete(article)
    assert_nil @repository.find_by(uuid: article.uuid)
  end

  def test_optimistic_locking_configuration_is_forwarded
    article = @repository.save(RepositoryArticle.new(title: "Original", metadata: {}))
    first = @repository.find(article.uuid)
    stale = @repository.find(article.uuid)

    first.title = "First writer"
    @repository.save(first)
    stale.title = "Stale writer"

    assert_raises(Lunula::Store::StaleObject) { @repository.save(stale) }
  end

  def test_requires_exactly_one_store_configuration
    unconfigured = Module.new { extend Lunula::Repository }

    error = assert_raises(Lunula::Error) { unconfigured.all }
    assert_includes error.message, "call store"

    configured = @repository
    database = @database
    error = assert_raises(Lunula::Error) do
      configured.module_eval do
        store database: database, table: :other, record: RepositoryArticle
      end
    end
    assert_includes error.message, "already configured"
  end
end
