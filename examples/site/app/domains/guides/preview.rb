# frozen_string_literal: true

module Guides
  module Preview
    module_function

    def title(value)
      title = value.to_s.strip
      title = "Untitled record" if title.empty?
      %(<h3 id="record-title">#{Hacienda::HTML.escape(title)}</h3>)
    end

    def comment(value)
      body = value.to_s.strip
      body = "No comment body was sent." if body.empty?
      timed_result("New comment added", body, tag: "article")
    end

    def post(message:, title:)
      content = message.to_s.strip
      content = title.to_s.strip if content.empty?
      content = "No message was entered." if content.empty?
      timed_result("Message posted", content, tag: "div")
    end

    def timed_result(label, content, tag:)
      created_at = Time.now
      <<~HTML
        <#{tag} class="ajax-result">
          <span class="eyebrow">
            #{label} ·
            <time
              datetime="#{created_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
              @text="time_ago_in_words(timestamp - #{created_at.to_f})"
            >Just now</time>
          </span>
          <p>#{Hacienda::HTML.escape(content)}</p>
        </#{tag}>
      HTML
    end
    private_class_method :timed_result
  end
end
