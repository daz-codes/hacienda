# frozen_string_literal: true

module Lunula
  module Jobs
    class RecurringSchedule
      Entry = Data.define(:name, :job_class, :interval, :args, :kwargs, :queue, :priority, :enabled)

      class << self
        def load(path)
          raise Error, "recurring schedule file not found: #{path}" unless File.file?(path)

          data = YAML.safe_load_file(path, aliases: false) || {}
          new(data, path:)
        rescue Psych::SyntaxError => error
          raise Error, "invalid recurring schedule #{path}: #{error.message}"
        end

        def set_enabled(path, name, enabled)
          raise Error, "recurring schedule file not found: #{path}" unless File.file?(path)

          data = YAML.safe_load_file(path, aliases: false) || {}
          tasks = tasks_hash(data)
          task = tasks[name.to_s] || raise(Error, "recurring task not found: #{name}")
          task["enabled"] = enabled
          File.write(path, YAML.dump(data))
          true
        end

        def tasks_hash(data)
          tasks = data.fetch("tasks", data)
          unless tasks.is_a?(Hash)
            raise Error, "recurring schedule must be a mapping or contain a tasks mapping"
          end

          tasks
        end
      end

      attr_reader :path, :entries

      def initialize(data, path:)
        @path = path
        @entries = self.class.tasks_hash(data).map do |name, attributes|
          build_entry(name, attributes || {})
        end.freeze
      end

      def enabled_entries
        entries.select(&:enabled)
      end

      def find(name)
        entries.find { |entry| entry.name == name.to_s }
      end

      def due_at(entry, now)
        timestamp = normalize_time(now).to_i
        Time.at(timestamp - (timestamp % entry.interval)).utc
      end

      private

      def build_entry(name, attributes)
        unless attributes.is_a?(Hash)
          raise Error, "recurring task #{name.inspect} must be a mapping"
        end

        job_class = required_string(attributes, "job", name)
        interval = parse_interval(attributes.fetch("every") { raise Error, "recurring task #{name.inspect} requires every" })
        args = attributes.fetch("args", [])
        kwargs = attributes.fetch("kwargs", {})
        unless args.is_a?(Array)
          raise Error, "recurring task #{name.inspect} args must be an array"
        end
        unless kwargs.is_a?(Hash)
          raise Error, "recurring task #{name.inspect} kwargs must be a mapping"
        end

        Entry.new(
          name: name.to_s,
          job_class:,
          interval:,
          args:,
          kwargs: kwargs.transform_keys(&:to_sym),
          queue: attributes["queue"]&.to_s,
          priority: attributes.key?("priority") ? Integer(attributes["priority"]) : nil,
          enabled: attributes.fetch("enabled", true) != false
        )
      rescue ArgumentError, TypeError
        raise Error, "recurring task #{name.inspect} priority must be an integer"
      end

      def required_string(attributes, key, name)
        value = attributes[key].to_s.strip
        raise Error, "recurring task #{name.inspect} requires #{key}" if value.empty?

        value
      end

      def parse_interval(value)
        return integer_interval(value) if value.is_a?(Numeric)

        text = value.to_s.strip.downcase
        match = text.match(/\A(\d+)\s*(s|sec|second|seconds|m|min|minute|minutes|h|hour|hours|d|day|days)\z/)
        raise Error, "recurring every value must look like '5 minutes', '1 hour', or an integer number of seconds" unless match

        count = Integer(match[1])
        unit = match[2]
        multiplier = case unit
        when "s", "sec", "second", "seconds" then 1
        when "m", "min", "minute", "minutes" then 60
        when "h", "hour", "hours" then 3600
        when "d", "day", "days" then 86_400
        end
        integer_interval(count * multiplier)
      end

      def integer_interval(value)
        seconds = Integer(value)
        raise Error, "recurring interval must be positive" unless seconds.positive?

        seconds
      rescue ArgumentError, TypeError
        raise Error, "recurring interval must be positive seconds"
      end

      def normalize_time(value)
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end
    end

    class RecurringScheduler
      Result = Data.define(:entry, :scheduled_at, :job_id)

      attr_reader :database, :adapter, :path, :table, :clock, :poll_interval

      def initialize(database:, adapter:, path:, table: :lunula_recurring_runs, clock: nil, poll_interval: 60)
        @database = database
        @adapter = Adapter.validate!(adapter)
        @path = path
        @table = table.to_sym
        @clock = clock || -> { Time.now.utc }
        @poll_interval = Float(poll_interval)
        @stopping = false
        raise ArgumentError, "recurring scheduler poll interval cannot be negative" if @poll_interval.negative?
      end

      def schedule
        RecurringSchedule.load(path)
      end

      def tick
        current_time = now
        current_schedule = schedule
        current_schedule.enabled_entries.filter_map do |entry|
          enqueue_entry(entry, scheduled_at: current_schedule.due_at(entry, current_time), current_time:)
        end
      end

      def trigger(name)
        entry = schedule.find(name) || raise(Error, "recurring task not found: #{name}")
        enqueue_entry(entry, scheduled_at: now, current_time: now, manual: true)
      end

      def stop
        @stopping = true
        self
      end

      def stopping?
        @stopping
      end

      def run
        until stopping?
          results = tick
          yield results if block_given?
          sleep poll_interval if results.empty? && poll_interval.positive? && !stopping?
        end
        self
      end

      private

      def enqueue_entry(entry, scheduled_at:, current_time:, manual: false)
        database.transaction do
          database[table].insert(
            task_name: entry.name,
            scheduled_at:,
            manual:,
            enqueued_job_id: nil,
            created_at: current_time
          )
          job = Jobs.constantize(entry.job_class)
          job_id = adapter.enqueue(
            job,
            args: entry.args,
            kwargs: entry.kwargs,
            queue: entry.queue,
            priority: entry.priority,
            scheduled_at: current_time,
            idempotency_key: "recurring:#{entry.name}:#{scheduled_at.to_i}"
          )
          database[table]
            .where(task_name: entry.name, scheduled_at:)
            .update(enqueued_job_id: job_id)
          Result.new(entry:, scheduled_at:, job_id:)
        end
      rescue Sequel::UniqueConstraintViolation
        nil
      rescue Sequel::DatabaseError => error
        raise Error, recurring_error(error)
      end

      def now
        value = clock.call
        value.respond_to?(:to_time) ? value.to_time.utc : value
      end

      def recurring_error(error)
        if error.message.match?(/no such table|does not exist/i)
          "recurring runs table #{table.inspect} is missing; run luna db:migrate"
        else
          error.message
        end
      end
    end
  end
end
