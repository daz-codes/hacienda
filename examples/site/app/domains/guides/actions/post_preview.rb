# frozen_string_literal: true

module Guides
  module PostPreview
    def self.respond(_context, params)
      message = params[:message].to_s.strip
      message = params[:title].to_s.strip if message.empty?
      message = "No message was entered." if message.empty?
      created_at = Time.now

      response <<~HTML
        <div class="ajax-result">
          <span class="eyebrow">
            Message posted ·
            <time
              datetime="#{created_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
              @text="time_ago_in_words(timestamp - #{created_at.to_f})"
            >Just now</time>
          </span>
          <p>#{Hacienda::HTML.escape(message)}</p>
        </div>
      HTML
    end
  end
end
