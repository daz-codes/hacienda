# frozen_string_literal: true

module Guides
  module CommentPreview
    def self.respond(_context, params)
      body = params[:body].to_s.strip
      body = "No comment body was sent." if body.empty?
      created_at = Time.now

      response <<~HTML
        <article class="ajax-result">
          <span class="eyebrow">
            New comment added ·
            <time
              datetime="#{created_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ")}"
              @text="time_ago_in_words(timestamp - #{created_at.to_f})"
            >Just now</time>
          </span>
          <p>#{Hacienda::HTML.escape(body)}</p>
        </article>
      HTML
    end
  end
end
