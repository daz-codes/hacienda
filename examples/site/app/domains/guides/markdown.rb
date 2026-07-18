# frozen_string_literal: true

require "cgi/escape"
require "rdoc"
require "rdoc/markdown"
require "rdoc/markup/to_html"

module Guides
  module Markdown
    module_function

    def render(source)
      source = source.gsub("](../examples/", "](https://github.com/hacienda-rb/hacienda/tree/main/examples/")
      markup = RDoc::Markdown.parse(source)
      html = RDoc::Markup::ToHtml.new(RDoc::Options.new).convert(markup)
      headings = []
      used_slugs = Hash.new(0)

      html.gsub!(%r{<h([1-3]) id="[^"]+">(.*?)</h\1>}m) do
        level = Regexp.last_match(1).to_i
        content = Regexp.last_match(2)
          .sub(%r{\A<a href="[^"]+">}, "")
          .sub(%r{</a>\z}, "")
          .sub(%r{<span>.*\z}m, "")
        title = CGI.unescape_html(content.gsub(%r{<[^>]+>}, "")).strip
        base = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|\z-/, "")
        used_slugs[base] += 1
        slug = used_slugs[base] == 1 ? base : "#{base}-#{used_slugs[base]}"
        headings << {level:, title:, id: slug} if level == 2
        %(<h#{level} id="#{slug}">#{content}</h#{level}>)
      end

      {
        html: Hacienda::HTML.safe(html),
        headings:
      }
    end
  end
end
