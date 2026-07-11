# frozen_string_literal: true

module Hacienda
  module Attributes
    UNDEFINED = Object.new.freeze
    Definition = Data.define(:name, :default, :cast)

    def self.included(base)
      base.extend ClassMethods
    end

    module ClassMethods
      def attribute(name, default: UNDEFINED, cast: nil)
        name = name.to_sym
        attribute_definitions[name] = Definition.new(name:, default:, cast:)

        define_method(name) { read_attribute(name) }
        define_method("#{name}=") { |value| write_attribute(name, value) }
        name
      end

      def attributes(*names, **options)
        names.each { |name| attribute(name, **options) }
      end

      def attribute_definitions
        @attribute_definitions ||= begin
          inherited = if superclass.respond_to?(:attribute_definitions)
            superclass.attribute_definitions
          else
            {}
          end
          inherited.dup
        end
      end

      def from_persistence(row)
        values = attribute_definitions.each_with_object({}) do |(name, _definition), loaded|
          next unless row.key?(name) || row.key?(name.to_s)

          value = row.key?(name) ? row[name] : row[name.to_s]
          loaded[name] = value
        end

        new(**values).tap(&:mark_persisted!)
      end
    end

    def initialize(**values)
      definitions = self.class.attribute_definitions
      unknown = values.keys.map(&:to_sym) - definitions.keys
      unless unknown.empty?
        raise ArgumentError, "unknown attributes: #{unknown.map(&:inspect).join(", ")}"
      end

      @attribute_values = {}
      @assigned_attribute_names = {}
      definitions.each do |name, definition|
        if values.key?(name) || values.key?(name.to_s)
          value = values.key?(name) ? values[name] : values[name.to_s]
          write_attribute(name, value)
        elsif !definition.default.equal?(UNDEFINED)
          write_attribute(name, default_for(definition))
        else
          @attribute_values[name] = nil
        end
      end

      @persisted = false
      snapshot_attributes!
    end

    def attributes
      self.class.attribute_definitions.keys.to_h { |name| [name, read_attribute(name)] }
    end

    def assign(attributes)
      attributes.each do |name, value|
        name = name.to_sym
        unless self.class.attribute_definitions.key?(name)
          raise ArgumentError, "unknown attribute: #{name.inspect}"
        end

        public_send("#{name}=", value)
      end
      self
    end

    def read_attribute(name)
      attribute_values[name.to_sym]
    end

    def write_attribute(name, value)
      name = name.to_sym
      definition = self.class.attribute_definitions.fetch(name)
      attribute_values[name] = definition.cast ? definition.cast.call(value) : value
      assigned_attributes[name] = true
    end

    def changed?
      !changed_attribute_names.empty?
    end

    def changed_attribute_names
      self.class.attribute_definitions.keys.select do |name|
        original_attributes[name] != attribute_values[name]
      end
    end

    def changes
      changed_attribute_names.to_h do |name|
        [name, [copy_value(original_attributes[name]), copy_value(attribute_values[name])]]
      end
    end

    def changed_attributes
      dump_attributes(changed_attribute_names)
    end

    def attribute_was(name)
      copy_value(original_attributes[name.to_sym])
    end

    def persisted?
      !!@persisted
    end

    def assigned_attribute_names
      assigned_attributes.keys
    end

    def mark_persisted!
      @persisted = true
      snapshot_attributes!
      self
    end

    def dump_attributes(names = self.class.attribute_definitions.keys)
      Array(names).to_h do |name|
        name = name.to_sym
        self.class.attribute_definitions.fetch(name)
        [name, read_attribute(name)]
      end
    end

    def apply_persistence_attributes!(values)
      values.each do |name, value|
        name = name.to_sym
        next unless self.class.attribute_definitions.key?(name)

        write_attribute(name, value)
      end
      self
    end

    private

    def attribute_values
      @attribute_values ||= {}
    end

    def original_attributes
      @original_attributes ||= {}
    end

    def assigned_attributes
      @assigned_attribute_names ||= {}
    end

    def snapshot_attributes!
      @original_attributes = attribute_values.to_h do |name, value|
        [name, copy_value(value)]
      end
    end

    def default_for(definition)
      return nil if definition.default.equal?(UNDEFINED)

      value = definition.default.respond_to?(:call) ? definition.default.call : definition.default
      copy_value(value)
    end

    def copy_value(value)
      case value
      when Hash
        value.to_h { |key, nested| [copy_value(key), copy_value(nested)] }
      when Array
        value.map { |nested| copy_value(nested) }
      else
        value.dup
      end
    rescue TypeError
      value
    end
  end
end
