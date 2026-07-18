# frozen_string_literal: true

require "sequel"

environment = Lunula.env.name
default_url = "sqlite://#{File.join(APP_ROOT, "db", "#{environment}.sqlite3")}"

DB = Sequel.connect(ENV.fetch("DATABASE_URL", default_url))
if DB.database_type == :sqlite
  Lunula::SQLite.configure(DB, wal: environment != "test")
end
