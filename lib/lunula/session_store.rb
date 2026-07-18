# frozen_string_literal: true

require "json"
require "rack/session/abstract/id"
require "sequel"

module Lunula
  class SessionStore < Rack::Session::Abstract::PersistedSecure
    DEFAULT_TABLE = :lunula_sessions

    attr_reader :database, :table

    def initialize(app, options = {})
      @database = options.delete(:database) || raise(ArgumentError, "Lunula::SessionStore requires database:")
      @table = (options.delete(:table) || DEFAULT_TABLE).to_sym
      @clock = options.delete(:clock) || -> { Time.now.utc }
      super
    end

    def revoke(session_id)
      dataset.where(id: private_session_id(session_id)).delete.positive?
    end

    def prune_expired(before: now)
      dataset.exclude(expires_at: nil).where { expires_at <= before }.delete
    end

    def self.create_table(database, table: DEFAULT_TABLE)
      database.create_table?(table) do
        String :id, primary_key: true
        String :data, text: true, null: false
        DateTime :expires_at
        DateTime :created_at, null: false
        DateTime :updated_at, null: false
        index :expires_at, name: :"#{table}_expires_at"
      end
    end

    private

    def find_session(_request, sid)
      if sid && (row = live_session(sid))
        [sid, decode(row.fetch(:data))]
      else
        [generate_sid, {}]
      end
    end

    def write_session(_request, sid, session, options)
      sid ||= generate_sid
      current_time = now
      attributes = {
        data: encode(session),
        expires_at: expires_at(options, current_time),
        updated_at: current_time
      }
      private_id = private_session_id(sid)
      changed = dataset.where(id: private_id).update(attributes)
      if changed.zero?
        dataset.insert(attributes.merge(id: private_id, created_at: current_time))
      end
      sid
    rescue Sequel::DatabaseError => error
      SQLite.report_busy(error, source: "session_store", table:)
      false
    end

    def delete_session(_request, sid, options)
      dataset.where(id: private_session_id(sid)).delete if sid
      options[:drop] ? nil : generate_sid
    rescue Sequel::DatabaseError => error
      SQLite.report_busy(error, source: "session_store", table:)
      options[:drop] ? nil : generate_sid
    end

    def live_session(sid)
      dataset
        .where(id: private_session_id(sid))
        .where(Sequel.|({expires_at: nil}, Sequel[:expires_at] > now))
        .first
    end

    def dataset
      database[table]
    end

    def private_session_id(session_id)
      return session_id.private_id if session_id.respond_to?(:private_id)

      text = session_id.to_s
      return text if text.match?(/\A2::[0-9a-f]{64}\z/)

      Rack::Session::SessionId.new(text).private_id
    end

    def encode(session)
      JSON.generate(session.to_h)
    end

    def decode(data)
      JSON.parse(data.to_s)
    rescue JSON::ParserError
      {}
    end

    def expires_at(options, current_time)
      seconds = options[:expire_after] || options[:max_age]
      seconds ? current_time + Integer(seconds) : nil
    end

    def now
      value = @clock.call
      value.respond_to?(:to_time) ? value.to_time.utc : value
    end
  end
end
