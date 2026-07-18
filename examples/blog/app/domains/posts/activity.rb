# frozen_string_literal: true

require "time"

module Posts
  module Activity
    module_function

    def record_published(event)
      record("post_published", event)
    end

    def record_archived(event)
      record("post_archived", event)
    end

    def record(name, event)
      Lunula.logger.info(
        "domain_event name=#{name.inspect} " \
        "post_id=#{event.post_id.inspect} " \
        "author_id=#{event.author_id.inspect} " \
        "occurred_at=#{event.occurred_at.iso8601.inspect}"
      )
    end
    private_class_method :record
  end
end
