# frozen_string_literal: true

require "sequel/extensions/migration"

module Lunula
  module Migrations
    module_function

    def pending(database:, directory:)
      files = migration_files(directory)
      return [] if files.empty?

      migrator = Sequel::Migrator.migrator_class(directory).new(database, directory)
      if migrator.is_a?(Sequel::TimestampMigrator)
        applied = migrator.applied_migrations.map { |name| name.to_s.downcase }
        files.reject { |path| applied.include?(File.basename(path).downcase) }
      else
        files.select { |path| migration_version(path) > migrator.current.to_i }
      end
    end

    def current?(database:, directory:)
      pending(database:, directory:).empty?
    end

    def migration_files(directory)
      return [] unless File.directory?(directory)

      Dir[File.join(directory, "*.rb")].select do |path|
        Sequel::Migrator::MIGRATION_FILE_PATTERN.match?(File.basename(path))
      end.sort
    end

    def migration_version(path)
      match = Sequel::Migrator::MIGRATION_FILE_PATTERN.match(File.basename(path))
      match ? match[1].to_i : -1
    end
    private_class_method :migration_version
  end
end
