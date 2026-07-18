# frozen_string_literal: true

module Lunula
  module Jobs
    module Adapters
      class Database
        attr_reader :database, :table, :queue, :workers_table, :queues_table, :lease_seconds,
          :heartbeat_interval, :default_execution_timeout, :worker_timeout,
          :completed_retention, :discarded_retention, :failed_retention

        def initialize(
          database:,
          table: :lunula_jobs,
          workers_table: :lunula_job_workers,
          queues_table: :lunula_job_queues,
          queue: "default",
          lease_seconds: 300,
          heartbeat_interval: nil,
          execution_timeout: nil,
          worker_timeout: nil,
          retry_delay: nil,
          completed_retention: 7 * 24 * 60 * 60,
          discarded_retention: 30 * 24 * 60 * 60,
          failed_retention: 30 * 24 * 60 * 60,
          clock: nil
        )
          @database = database
          @table = table.to_sym
          @workers_table = workers_table.to_sym
          @queues_table = queues_table.to_sym
          @queue = queue.to_s
          @queue_cursor = 0
          @queue_mutex = Mutex.new
          @clock = clock || -> { Time.now.utc }
          @lease_seconds = Float(lease_seconds)
          @heartbeat_interval = Float(heartbeat_interval || [@lease_seconds / 3.0, 30.0].min)
          @default_execution_timeout = execution_timeout && Float(execution_timeout)
          @worker_timeout = Float(worker_timeout || [@lease_seconds * 2.0, 60.0].max)
          @completed_retention = normalize_retention(completed_retention)
          @discarded_retention = normalize_retention(discarded_retention)
          @failed_retention = normalize_retention(failed_retention)
          raise ArgumentError, "heartbeat_interval must be positive and shorter than lease_seconds" unless @heartbeat_interval.positive? && @heartbeat_interval < @lease_seconds
          if @default_execution_timeout && (!@default_execution_timeout.positive? || !@default_execution_timeout.finite?)
            raise ArgumentError, "execution_timeout must be positive and finite"
          end
          raise ArgumentError, "worker_timeout must be positive" unless @worker_timeout.positive?
          @durable_queue = Durable::Queue.new(
            database:,
            table:,
            lease_seconds: @lease_seconds,
            retry_delay:,
            clock: @clock,
            order: %i[priority available_at id],
            complete_attributes: ->(at) do
              {
                completed_at: at,
                locked_at: nil,
                locked_by: nil,
                worker_id: nil,
                last_error: nil,
                failure_kind: nil,
                cancel_requested_at: nil,
                updated_at: at
              }
            end,
            terminal_attributes: ->(at) { {discarded_at: at} },
            terminal_filters: {completed_at: nil, discarded_at: nil}
          )
        end

        def capabilities = %i[durable transactional worker scheduled priorities uniqueness concurrency bulk]

        def transactional_with?(candidate)
          database.equal?(candidate)
        end

        def enqueue(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, idempotency_key: nil)
          attributes = build_job_attributes(
            job,
            args:,
            kwargs:,
            queue:,
            priority:,
            scheduled_at:,
            current_time: now
          )
          id = insert_job_attributes(attributes, job)
          Jobs.instrument(:enqueue, id:, job_class: attributes.fetch(:job_class), queue: attributes.fetch(:queue), scheduled_at:)
          id
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def enqueue_all(entries)
          normalized_entries = entries.map { |entry| Jobs.normalize_enqueue_entry(entry) }
          ids = []
          database.transaction do
            normalized_entries.each do |entry|
              attributes = build_job_attributes(
                entry.fetch(:job),
                args: entry.fetch(:args),
                kwargs: entry.fetch(:kwargs),
                queue: entry[:queue],
                priority: entry[:priority],
                scheduled_at: entry[:scheduled_at],
                current_time: now
              )
              ids << insert_job_attributes(attributes, entry.fetch(:job))
            end
          end
          Jobs.instrument(:enqueue_bulk, ids:, count: ids.length)
          ids
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def build_job_attributes(job, args:, kwargs:, queue: nil, priority: nil, scheduled_at: nil, current_time:)
          job_name = Jobs.job_name(job)
          max_attempts = job.respond_to?(:max_attempts) ? Integer(job.max_attempts) : 10
          raise Error, "job max_attempts must be positive" unless max_attempts.positive?

          queue_name = queue || (job.respond_to?(:queue) ? job.queue.to_s : self.queue)
          unique_key = Jobs.unique_key(job, args:, kwargs:)
          unique_until = unique_key && current_time + Jobs.unique_for(job)
          concurrency_key = Jobs.concurrency_key(job, args:, kwargs:)
          concurrency_limit = concurrency_key && Jobs.concurrency_limit(job)
          attributes = queue_block_attributes(queue_name, at: current_time)
          attributes.merge(
            queue: queue_name,
            priority: priority || Jobs.priority(job),
            job_class: job_name,
            payload: Serializer.dump(args:, kwargs:),
            attempts: 0,
            max_attempts:,
            available_at: Jobs.normalize_scheduled_at(scheduled_at) || current_time,
            locked_at: nil,
            locked_by: nil,
            last_error: nil,
            failed_at: nil,
            unique_key:,
            unique_until:,
            concurrency_key:,
            concurrency_limit:,
            created_at: current_time,
            updated_at: current_time
          )
        end

        def insert_job_attributes(attributes, job)
          current_time = now
          unique_key = attributes[:unique_key]
          id = database.transaction(savepoint: true) do
            if unique_key
              existing = dataset
                .where(unique_key:)
                .where(discarded_at: nil)
                .order(:id)
                .all
                .find { |row| future_wall_time?(row[:unique_until], current_time) }
              if existing
                case Jobs.unique_conflict(job)
                when :keep
                  existing.fetch(:id)
                when :raise
                  raise Error, "unique job already exists for #{unique_key.inspect}"
                end
              else
                dataset.insert(attributes)
              end
            else
              dataset.insert(attributes)
            end
          end
          id
        end

        def work_once(queue: self.queue)
          claim = claim_many(queues: [queue], limit: 1).first
          return unless claim

          perform_claim(claim)
        end

        def claim_many(queues:, limit:, worker_id: nil)
          recover_abandoned_workers if worker_id
          selected = normalize_queues(queues)
          claim_attributes = {blocked_at: nil, blocked_reason: nil}
          claim_attributes[:worker_id] = worker_id.to_s if worker_id
          return @durable_queue.claim_many(limit:, filters: {}, claim_attributes:, before_claim: method(:claim_allowed?)) if selected == :all

          limit = Integer(limit)
          raise ArgumentError, "claim limit must be positive" unless limit.positive?

          start = @queue_mutex.synchronize do
            current = @queue_cursor
            @queue_cursor = (@queue_cursor + 1) % selected.length
            current
          end
          claims = []
          empty_queues = 0
          offset = 0
          while claims.length < limit && empty_queues < selected.length
            queue_name = selected[(start + offset) % selected.length]
            claim = @durable_queue.claim(filters: {queue: queue_name}, claim_attributes:, before_claim: method(:claim_allowed?))
            if claim
              claims << claim
              empty_queues = 0
            else
              empty_queues += 1
            end
            offset += 1
          end
          claims
        end

        def perform_claim(claim)
          context = nil
          monitor = nil
          begin
            args, kwargs = Serializer.load(claim.row.fetch(:payload))
            job = Jobs.constantize(claim.row.fetch(:job_class))
            context = ExecutionContext.new(timeout: Jobs.execution_timeout(job, default: default_execution_timeout))
            monitor = start_claim_monitor(claim, context)
            Jobs.instrument(:start, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), attempt: claim.row.fetch(:attempts))
            Jobs.with_execution_context(context) do
              Jobs.perform(job, args:, kwargs:)
              context.cancel! if cancellation_requested?(claim)
              Jobs.checkpoint!
            end
            @durable_queue.complete(claim)
            Jobs.instrument(:finish, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), status: :succeeded)
            Execution.new(id: claim.row.fetch(:id), status: :succeeded, error: nil)
          rescue TimeoutError => error
            outcome = @durable_queue.fail_claim(
              claim,
              error,
              kind: "timeout",
              release_attributes: {worker_id: nil}
            )
            status = outcome ? :timed_out : :lease_lost
            Jobs.instrument(:timeout, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), status:)
            Jobs.instrument(:discard, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), kind: "timeout") if outcome == :terminal
            Execution.new(id: claim.row.fetch(:id), status:, error:)
          rescue CancelledError => error
            @durable_queue.terminate_claim(
              claim,
              error,
              kind: "cancelled",
              release_attributes: {worker_id: nil, cancelled_at: now, cancel_requested_at: nil}
            )
            Jobs.instrument(:discard, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), kind: "cancelled")
            Execution.new(id: claim.row.fetch(:id), status: :cancelled, error:)
          rescue Durable::LeaseLost => error
            Jobs.instrument(:lease_loss, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue))
            Execution.new(id: claim.row.fetch(:id), status: :lease_lost, error:)
          rescue StandardError => error
            outcome = @durable_queue.fail_claim(
              claim,
              error,
              kind: "error",
              release_attributes: {worker_id: nil}
            )
            status = if outcome == :terminal
              :failed
            elsif outcome == :retrying
              :retrying
            else
              :lease_lost
            end
            case status
            when :retrying
              Jobs.instrument(:retry, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), error: error.message)
            when :failed
              Jobs.instrument(:discard, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue), kind: "error", error: error.message)
            when :lease_lost
              Jobs.instrument(:lease_loss, id: claim.row.fetch(:id), job_class: claim.row.fetch(:job_class), queue: claim.row.fetch(:queue))
            end
            Execution.new(id: claim.row.fetch(:id), status:, error:)
          ensure
            stop_claim_monitor(monitor)
          end
        end

        def register_worker(attributes)
          database[workers_table].insert(attributes)
          true
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def heartbeat_worker(id, current_workload: nil)
          attributes = {last_heartbeat_at: now}
          attributes[:current_workload] = Integer(current_workload) unless current_workload.nil?
          database[workers_table].where(id:).update(attributes) == 1
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def unregister_worker(id)
          database[workers_table].where(id:).delete
          true
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def workers
          database[workers_table].order(:started_at, :id).all
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def paused_queues
          database[queues_table].order(:queue).all
        rescue Sequel::DatabaseError => error
          raise Error, queue_error(error)
        end

        def pause_queue(queue, by: nil)
          queue_name = queue.to_s
          raise Error, "queue name is required" if queue_name.empty?

          current_time = now
          database.transaction do
            changed = database[queues_table]
              .where(queue: queue_name)
              .update(paused_at: current_time, paused_by: by&.to_s, updated_at: current_time)
            if changed.zero?
              database[queues_table].insert(
                queue: queue_name,
                paused_at: current_time,
                paused_by: by&.to_s,
                created_at: current_time,
                updated_at: current_time
              )
            end
            active_scope.where(queue: queue_name, locked_at: nil).update(
              blocked_at: current_time,
              blocked_reason: paused_reason(queue_name),
              updated_at: current_time
            )
          end
          true
        rescue Sequel::DatabaseError => error
          raise Error, queue_error(error)
        end

        def resume_queue(queue)
          queue_name = queue.to_s
          raise Error, "queue name is required" if queue_name.empty?

          current_time = now
          database.transaction do
            database[queues_table].where(queue: queue_name).delete
            active_scope
              .where(queue: queue_name, locked_at: nil, blocked_reason: paused_reason(queue_name))
              .update(blocked_at: nil, blocked_reason: nil, updated_at: current_time)
          end
          true
        rescue Sequel::DatabaseError => error
          raise Error, queue_error(error)
        end

        def discard(id, reason: nil)
          current_time = now
          active_scope
            .where(id: Integer(id), locked_at: nil)
            .update(
              failed_at: current_time,
              discarded_at: current_time,
              failure_kind: "discarded",
              last_error: "Lunula::Jobs::Discarded: #{reason || "discarded by operator"}",
              blocked_at: nil,
              blocked_reason: nil,
              updated_at: current_time
            ) == 1
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def reschedule(id, at:)
          scheduled_at = Jobs.normalize_scheduled_at(at) || now
          row = active_scope.where(id: Integer(id), locked_at: nil).first
          return false unless row

          current_time = now
          active_scope
            .where(id: row.fetch(:id), locked_at: nil)
            .update({
              available_at: scheduled_at,
              updated_at: current_time
            }.merge(queue_block_attributes(row.fetch(:queue), at: current_time))) == 1
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def failed
          @durable_queue.failed
        end

        def pending
          current_time = now
          active_scope
            .where(locked_at: nil)
            .where(blocked_at: nil)
            .where { available_at <= current_time }
            .order(:priority, :available_at, :id)
            .all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def running
          active_scope
            .exclude(locked_at: nil)
            .order(:locked_at, :id)
            .all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def blocked(limit: 50)
          limited(
            active_scope
              .where(locked_at: nil)
              .exclude(blocked_at: nil)
              .order(:blocked_at, :priority, :available_at, :id),
            limit
          ).all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def completed(limit: 50)
          limited(dataset.exclude(completed_at: nil).reverse_order(:completed_at, :id), limit).all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def discarded(limit: 50)
          limited(dataset.exclude(discarded_at: nil).reverse_order(:discarded_at, :id), limit).all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def status
          current_time = now
          oldest = pending.first
          {
            pending: pending.length,
            scheduled: scheduled.length,
            running: running.length,
            blocked: blocked.length,
            paused_queues: paused_queues.length,
            completed: dataset.exclude(completed_at: nil).count,
            discarded: dataset.exclude(discarded_at: nil).count,
            failed: dataset.exclude(failed_at: nil).count,
            workers: workers.length,
            oldest_pending_age: oldest && (current_time - wall_time_utc(oldest.fetch(:created_at))).to_i,
            completed_last_minute: dataset.where { completed_at >= current_time - 60 }.count,
            completed_last_hour: dataset.where { completed_at >= current_time - 3600 }.count
          }
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def health(pending_warn_after: 300, pending_critical_after: 3600)
          current_time = now
          metrics = status
          stale_workers = workers.select do |row|
            timestamp = row[:last_heartbeat_at]
            timestamp && wall_time_utc(timestamp) <= current_time - worker_timeout
          end
          oldest_age = metrics[:oldest_pending_age].to_i if metrics[:oldest_pending_age]

          level = "ok"
          level = "warn" if metrics.fetch(:failed).positive? || stale_workers.any? ||
            (oldest_age && oldest_age >= pending_warn_after)
          level = "critical" if oldest_age && oldest_age >= pending_critical_after

          {
            status: level,
            generated_at: current_time,
            checks: {
              failed_jobs: metrics.fetch(:failed),
              stale_workers: stale_workers.length,
              oldest_pending_age: metrics[:oldest_pending_age],
              paused_queues: metrics.fetch(:paused_queues),
              running_jobs: metrics.fetch(:running)
            }
          }
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def prune(completed_before: nil, discarded_before: nil, failed_before: nil)
          counts = {completed: 0, discarded: 0, failed: 0}
          database.transaction do
            if completed_before
              counts[:completed] = dataset.where { completed_at <= completed_before }.delete
            end
            if discarded_before
              counts[:discarded] = dataset.where { discarded_at <= discarded_before }.delete
            end
            if failed_before
              counts[:failed] = dataset.where { failed_at <= failed_before }.delete
            end
          end
          counts
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def retry_failed(id)
          @durable_queue.retry_failed(
            id,
            reset_attributes: {
              worker_id: nil,
              cancel_requested_at: nil,
              cancelled_at: nil,
              discarded_at: nil,
              blocked_at: nil,
              blocked_reason: nil
            }
          )
        end

        def cancel(id)
          row = database[table].where(id: Integer(id)).first
          return false unless row

          current_time = now
          if row[:locked_at]
            database[table].where(id: row.fetch(:id), locked_by: row[:locked_by]).update(
              cancel_requested_at: current_time,
              updated_at: current_time
            ) == 1
          else
            active_scope.where(id: row.fetch(:id)).update(
              failed_at: current_time,
              discarded_at: current_time,
              cancelled_at: current_time,
              cancel_requested_at: nil,
              failure_kind: "cancelled",
              last_error: "Lunula::Jobs::CancelledError: job cancellation was requested",
              updated_at: current_time
            ) == 1
          end
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        def pending_count
          @durable_queue.pending_count
        end

        def scheduled
          current_time = now
          active_scope
            .where(locked_at: nil)
            .where(blocked_at: nil)
            .where { available_at > current_time }
            .order(:available_at, :priority, :id)
            .all
        rescue Sequel::DatabaseError => error
          raise Error, durable_error(error)
        end

        private

        Monitor = Data.define(:thread, :mutex, :condition, :state)

        def start_claim_monitor(claim, context)
          mutex = Mutex.new
          condition = ConditionVariable.new
          state = {stopped: false}
          thread = Thread.new do
            loop do
              stopped = mutex.synchronize do
                condition.wait(mutex, heartbeat_interval) unless state[:stopped]
                state[:stopped]
              end
              break if stopped

              begin
                @durable_queue.renew(claim)
                worker_id = claim.row[:worker_id]
                heartbeat_worker(worker_id) if worker_id
                context.cancel! if cancellation_requested?(claim)
                context.poll!
              rescue Durable::LeaseLost
                context.lease_lost!
                break
              rescue Durable::Error, Error => error
                Lunula.logger.error("job_lease_renewal_failed job_id=#{claim.row.fetch(:id)} error=#{error.class}: #{error.message}")
              end
            end
          end
          Monitor.new(thread:, mutex:, condition:, state:)
        end

        def stop_claim_monitor(monitor)
          return unless monitor

          monitor.mutex.synchronize do
            monitor.state[:stopped] = true
            monitor.condition.broadcast
          end
          monitor.thread.join
        end

        def cancellation_requested?(claim)
          !database[table]
            .where(id: claim.row.fetch(:id), locked_by: claim.token)
            .get(:cancel_requested_at)
            .nil?
        end

        def claim_allowed?(row)
          if queue_paused?(row.fetch(:queue))
            current_time = now
            dataset.where(id: row.fetch(:id), locked_at: nil).update(
              blocked_at: current_time,
              blocked_reason: paused_reason(row.fetch(:queue)),
              updated_at: current_time
            )
            return false
          end

          key = row[:concurrency_key].to_s
          limit = row[:concurrency_limit].to_i
          return true if key.empty? || !limit.positive?

          running = active_scope
            .where(concurrency_key: key)
            .exclude(locked_at: nil)
            .count
          if running >= limit
            current_time = now
            dataset.where(id: row.fetch(:id), locked_at: nil).update(
              blocked_at: current_time,
              blocked_reason: "concurrency limit #{limit} reached for #{key}",
              updated_at: current_time
            )
            false
          else
            true
          end
        end

        def recover_abandoned_workers
          current_time = now
          cutoff = current_time - worker_timeout
          stale_ids = database[workers_table].where { last_heartbeat_at <= cutoff }.select_map(:id)
          return 0 if stale_ids.empty?

          recovered = 0
          database.transaction do
            scope = database[table]
              .where(worker_id: stale_ids, failed_at: nil)
              .exclude(locked_at: nil)
            retryable = scope.where { attempts < max_attempts }
            recovered += retryable.update(
              available_at: current_time,
              locked_at: nil,
              locked_by: nil,
              worker_id: nil,
              failure_kind: "abandoned",
              last_error: "Lunula::Jobs::Error: worker heartbeat expired",
              updated_at: current_time
            )
            exhausted = scope.where { attempts >= max_attempts }
            recovered += exhausted.update(
              locked_at: nil,
              locked_by: nil,
              worker_id: nil,
              failed_at: current_time,
              discarded_at: current_time,
              failure_kind: "abandoned",
              last_error: "Lunula::Jobs::Error: worker heartbeat expired after final attempt",
              updated_at: current_time
            )
            database[workers_table].where(id: stale_ids).delete
          end
          recovered
        rescue Sequel::DatabaseError => error
          raise Error, worker_error(error)
        end

        def normalize_queues(values)
          return :all if values == :all

          queues = Array(values).flat_map { |value| value.to_s.split(",") }.map(&:strip).reject(&:empty?)
          return :all if queues.include?("*") || queues.include?("all")
          raise ArgumentError, "at least one queue is required" if queues.empty?

          queues.uniq
        end

        def active_scope
          dataset.where(failed_at: nil, completed_at: nil, discarded_at: nil)
        end

        def dataset
          database[table]
        end

        def limited(scope, limit)
          limit ? scope.limit(Integer(limit)) : scope
        end

        def queue_block_attributes(queue, at:)
          if queue_paused?(queue)
            {blocked_at: at, blocked_reason: paused_reason(queue)}
          else
            {blocked_at: nil, blocked_reason: nil}
          end
        end

        def queue_paused?(queue)
          database[queues_table].where(queue: queue.to_s).count.positive?
        rescue Sequel::DatabaseError
          false
        end

        def paused_reason(queue)
          "queue #{queue} is paused"
        end

        def normalize_retention(value)
          return if value.nil? || value == false

          seconds = Float(value)
          raise ArgumentError, "job retention values must be positive seconds" unless seconds.positive? && seconds.finite?

          seconds
        end

        def future_wall_time?(value, current_time)
          return false unless value

          time = value.respond_to?(:to_time) ? value.to_time : value
          time.strftime("%Y%m%d%H%M%S.%6N") > current_time.strftime("%Y%m%d%H%M%S.%6N")
        end

        def wall_time_utc(value)
          time = value.respond_to?(:to_time) ? value.to_time : value
          return time unless time.respond_to?(:year)

          Time.utc(time.year, time.month, time.day, time.hour, time.min, time.sec, time.respond_to?(:usec) ? time.usec : 0)
        end

        def now
          value = @clock.call
          value.respond_to?(:to_time) ? value.to_time.utc : value
        end

        def durable_error(error)
          SQLite.report_busy(error, source: "jobs", table:)
          if error.message.match?(/no such table|does not exist/i)
            "durable jobs table #{table.inspect} is missing; run luna db:migrate"
          else
            error.message
          end
        end

        def worker_error(error)
          SQLite.report_busy(error, source: "jobs_workers", table: workers_table)
          if error.message.match?(/no such table|does not exist/i)
            "job workers table #{workers_table.inspect} is missing; run luna db:migrate"
          else
            error.message
          end
        end

        def queue_error(error)
          SQLite.report_busy(error, source: "jobs_queues", table: queues_table)
          if error.message.match?(/no such table|does not exist/i)
            "job queues table #{queues_table.inspect} is missing; run luna db:migrate"
          else
            error.message
          end
        end
      end
    end
  end
end
