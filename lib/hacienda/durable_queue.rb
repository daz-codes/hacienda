# frozen_string_literal: true

require "securerandom"
require "sequel"

module Hacienda
  module Durable
    class Error < Hacienda::Error; end
    class LeaseLost < Error; end

    Claim = Data.define(:row, :token)

    class Queue
      attr_reader :database, :table, :lease_seconds, :retry_delay, :order

      def initialize(
        database:,
        table:,
        lease_seconds: 300,
        retry_delay: nil,
        clock: nil,
        order: %i[available_at id],
        complete_attributes: nil,
        terminal_attributes: nil,
        terminal_filters: {}
      )
        @database = database
        @table = table.to_sym
        @lease_seconds = Float(lease_seconds)
        raise ArgumentError, "lease_seconds must be positive" unless @lease_seconds.positive?

        @retry_delay = retry_delay || ->(attempt) { [2**(attempt - 1), 300].min }
        @clock = clock || -> { Time.now.utc }
        @order = Array(order).map(&:to_sym).freeze
        raise ArgumentError, "durable queue order cannot be empty" if @order.empty?
        @complete_attributes = complete_attributes
        @terminal_attributes = terminal_attributes
        @terminal_filters = terminal_filters.transform_keys(&:to_sym).freeze
      end

      def claim(filters: {}, claim_attributes: {}, before_claim: nil)
        claim_many(limit: 1, filters:, claim_attributes:, before_claim:).first
      end

      def claim_many(limit:, filters: {}, claim_attributes: {}, before_claim: nil)
        limit = Integer(limit)
        raise ArgumentError, "claim limit must be positive" unless limit.positive?

        current_time = now
        expire_exhausted_leases(at: current_time)
        candidate_limit = [limit * 10, 100].max
        candidates = eligible(filters:, at: current_time).limit(candidate_limit).select_map(:id)
        claims = []
        candidates.each do |id|
          token = SecureRandom.uuid
          attributes = {
            locked_at: current_time,
            locked_by: token,
            attempts: Sequel[:attempts] + 1,
            updated_at: current_time
          }.merge(claim_attributes)
          row = eligible(filters:, at: current_time).where(id:).first
          next unless row
          next if before_claim && before_claim.call(row) != true

          claimed = eligible(filters:, at: current_time)
            .where(id:)
            .update(attributes)
          next unless claimed == 1

          claims << Claim.new(row: dataset.where(id:, locked_by: token).first, token:)
          break if claims.length >= limit
        end
        claims
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def complete(claim)
        scope = dataset.where(id: claim.row.fetch(:id), locked_by: claim.token)
        changed = if @complete_attributes
          scope.update(attributes_for(@complete_attributes, at: now))
        else
          scope.delete
        end
        raise LeaseLost, "durable work #{claim.row.fetch(:id)} no longer owns its lease" unless changed == 1

        true
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def renew(claim)
        renewed = dataset
          .where(id: claim.row.fetch(:id), locked_by: claim.token, failed_at: nil)
          .update(locked_at: now, updated_at: now)
        unless renewed == 1
          raise LeaseLost, "durable work #{claim.row.fetch(:id)} no longer owns its lease"
        end

        true
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def fail_claim(claim, error, kind: "error", release_attributes: {})
        row = dataset.where(id: claim.row.fetch(:id), locked_by: claim.token).first
        return false unless row

        current_time = now
        attempts = row.fetch(:attempts).to_i
        attributes = {
          locked_at: nil,
          locked_by: nil,
          last_error: error_text(error),
          failure_kind: kind.to_s,
          updated_at: current_time
        }.merge(release_attributes)
        terminal = attempts >= row.fetch(:max_attempts).to_i
        if terminal
          attributes[:failed_at] = current_time
          attributes.merge!(attributes_for(@terminal_attributes, at: current_time))
        else
          attributes[:available_at] = current_time + Float(retry_delay.call(attempts))
        end
        updated = dataset.where(id: row.fetch(:id), locked_by: claim.token).update(attributes)
        return false unless updated == 1

        terminal ? :terminal : :retrying
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def terminate_claim(claim, error, kind:, release_attributes: {})
        current_time = now
        attributes = {
          locked_at: nil,
          locked_by: nil,
          failed_at: current_time,
          last_error: error_text(error),
          failure_kind: kind.to_s,
          updated_at: current_time
        }.merge(release_attributes)
        attributes.merge!(attributes_for(@terminal_attributes, at: current_time))
        updated = dataset.where(id: claim.row.fetch(:id), locked_by: claim.token).update(attributes)
        raise LeaseLost, "durable work #{claim.row.fetch(:id)} no longer owns its lease" unless updated == 1

        :terminal
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def retry_failed(id, reset_attributes: {})
        attributes = {
          attempts: 0,
          available_at: now,
          locked_at: nil,
          locked_by: nil,
          last_error: nil,
          failure_kind: nil,
          failed_at: nil,
          updated_at: now
        }.merge(reset_attributes)
        dataset.where(id: Integer(id)).exclude(failed_at: nil).update(attributes) == 1
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def failed
        dataset.exclude(failed_at: nil).order(:failed_at).all
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      def pending_count
        scope = dataset.where(failed_at: nil)
        scope = scope.where(@terminal_filters) unless @terminal_filters.empty?
        scope.count
      rescue Sequel::DatabaseError => error
        raise Error, queue_error(error)
      end

      private

      def dataset
        database[table]
      end

      def eligible(filters:, at:)
        cutoff = at - lease_seconds
        scope = dataset.where(failed_at: nil).where { attempts < max_attempts }
        scope = scope.where(@terminal_filters) unless @terminal_filters.empty?
        filters.each { |key, value| scope = scope.where(key => value) }
        scope.where { available_at <= at }
          .where(Sequel.|({locked_at: nil}, Sequel[:locked_at] <= cutoff))
          .order(*order)
      end

      def expire_exhausted_leases(at:)
        cutoff = at - lease_seconds
        dataset
          .where(failed_at: nil)
          .exclude(locked_at: nil)
          .where { locked_at <= cutoff }
          .where { attempts >= max_attempts }
          .update({
            locked_at: nil,
            locked_by: nil,
            failed_at: at,
            last_error: "Hacienda::Durable::LeaseExpired: worker stopped before completing its final attempt",
            failure_kind: "lease_expired",
            updated_at: at
          }.merge(attributes_for(@terminal_attributes, at:)))
      end

      def attributes_for(source, at:)
        case source
        when nil then {}
        when Proc then source.call(at)
        else source
        end.to_h
      end

      def now
        value = @clock.call
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end

      def error_text(error)
        text = "#{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}"
        text.byteslice(0, 16_000)
      end

      def queue_error(error)
        SQLite.report_busy(error, source: "durable_queue", table:)
        if error.message.match?(/no such table|does not exist/i)
          "durable queue table #{table.inspect} is missing; run hac db:migrate"
        else
          error.message
        end
      end
    end
  end
end
