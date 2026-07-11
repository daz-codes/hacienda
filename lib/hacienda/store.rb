# frozen_string_literal: true

module Hacienda
  class Store
    class StaleObject < Hacienda::Error; end

    attr_reader :database, :table, :record_class, :primary_key, :lock_attribute

    def initialize(
      database:,
      table:,
      record:,
      primary_key: :id,
      timestamps: true,
      lock: nil,
      coercions: {},
      refresh: :insert,
      clock: nil
    )
      @database = database
      @table = table.to_sym
      @record_class = record
      @primary_key = primary_key.to_sym
      @timestamps = timestamps
      @lock_attribute = lock&.to_sym
      @coercions = normalize_coercions(coercions)
      @refresh = refresh
      @clock = clock || -> { Time.now }

      validate_record!
    end

    def dataset
      database[table]
    end

    def all(scope = dataset)
      scope.all.map { |row| load(row) }
    end

    def first(scope = dataset)
      row = scope.first
      load(row) if row
    end

    def find(id)
      first(dataset.where(primary_key => id)) || raise(NotFound)
    end

    def load(row)
      record_class.from_persistence(load_values(row))
    end

    def save(record)
      primary_key_value(record).nil? ? insert(record) : update(record)
    end

    def delete(record)
      scope = dataset.where(primary_key => primary_key_value(record))
      scope = scope.where(lock_attribute => record.attribute_was(lock_attribute)) if lock_attribute
      deleted = scope.delete
      raise_stale!(record) if lock_attribute && deleted.zero?
      record
    end

    def refresh(record)
      row = dataset.where(primary_key => primary_key_value(record)).first
      raise NotFound unless row

      apply_row(record, row)
      record.mark_persisted!
    end

    private

    def insert(record)
      now = @clock.call
      write_timestamp(record, :created_at, now)
      write_timestamp(record, :updated_at, now)
      record.public_send("#{lock_attribute}=", 0) if lock_attribute && record.public_send(lock_attribute).nil?

      names = record.assigned_attribute_names - [primary_key]
      previous_primary_key = primary_key_value(record)
      id = dataset.insert(dump_values(record.dump_attributes(names)))
      record.public_send("#{primary_key}=", id)
      database.after_rollback(savepoint: true) do
        record.public_send("#{primary_key}=", previous_primary_key)
      end
      refresh_from_database(record) if refresh_after_insert?
      mark_clean_after_commit(record)
      record
    end

    def update(record)
      meaningful_changes = record.changed_attributes.keys - [primary_key, :updated_at, lock_attribute].compact
      return record if meaningful_changes.empty?

      now = @clock.call
      write_timestamp(record, :updated_at, now)
      values = dump_values(record.changed_attributes.reject { |name, _value| name == primary_key })

      if lock_attribute
        previous_lock = record.attribute_was(lock_attribute).to_i
        next_lock = previous_lock + 1
        values[lock_attribute] = next_lock
        updated = dataset
          .where(primary_key => primary_key_value(record), lock_attribute => previous_lock)
          .update(values)
        raise_stale!(record) if updated.zero?
        record.public_send("#{lock_attribute}=", next_lock)
      elsif values.any?
        dataset.where(primary_key => primary_key_value(record)).update(values)
      end

      refresh_from_database(record) if refresh_after_update?
      mark_clean_after_commit(record)
      record
    end

    def write_timestamp(record, name, value)
      return unless @timestamps
      return unless record.class.attribute_definitions.key?(name)

      record.public_send("#{name}=", value)
    end

    def primary_key_value(record)
      record.public_send(primary_key)
    end

    def raise_stale!(record)
      raise StaleObject,
        "stale #{record.class} with #{primary_key}=#{primary_key_value(record).inspect}"
    end

    def load_values(row)
      row.each_with_object({}) do |(name, value), values|
        name = name.to_sym
        next unless record_class.attribute_definitions.key?(name)

        coercion = @coercions[name]
        values[name] = coercion && coercion[:load] ? coercion[:load].call(value) : value
      end
    end

    def dump_values(attributes)
      attributes.to_h do |name, value|
        coercion = @coercions[name]
        [name, coercion && coercion[:dump] ? coercion[:dump].call(value) : value]
      end
    end

    def apply_row(record, row)
      record.apply_persistence_attributes!(load_values(row))
    end

    def refresh_from_database(record)
      row = dataset.where(primary_key => primary_key_value(record)).first
      apply_row(record, row) if row
    end

    def refresh_after_insert?
      @refresh == true || @refresh == :insert || @refresh == :always
    end

    def refresh_after_update?
      @refresh == true || @refresh == :always
    end

    def mark_clean_after_commit(record)
      database.after_commit(savepoint: true) { record.mark_persisted! }
    end

    def normalize_coercions(coercions)
      coercions.to_h do |name, configuration|
        configuration = configuration.to_h
        [name.to_sym, {load: configuration[:load], dump: configuration[:dump]}]
      end
    end

    def validate_record!
      unless record_class.respond_to?(:attribute_definitions) && record_class.respond_to?(:from_persistence)
        raise ArgumentError, "record must include Hacienda::Attributes"
      end
      unless record_class.attribute_definitions.key?(primary_key)
        raise ArgumentError, "record must declare primary key attribute #{primary_key.inspect}"
      end
      if lock_attribute && !record_class.attribute_definitions.key?(lock_attribute)
        raise ArgumentError, "record must declare lock attribute #{lock_attribute.inspect}"
      end
    end
  end
end
