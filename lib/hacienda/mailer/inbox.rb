# frozen_string_literal: true

require "erb"

module Hacienda
  module Mailer
    class Inbox
      MESSAGE_ID = /\A\d{20}-[0-9a-f]{8}\.eml\z/
      MAX_LINKS = 50

      def initialize(root:, environment: Hacienda.env, authorized: nil)
        @root = File.expand_path(root)
        @environment = environment
        @authorized = authorized
      end

      def call(env)
        request = Rack::Request.new(env)
        return not_found if production?
        return forbidden unless authorized?(request)

        segments = request.path_info.to_s.split("/").reject(&:empty?)
        case [request.request_method, segments.length]
        when ["GET", 0]
          html_response(index_page(request))
        when ["GET", 1]
          html_response(message_page(load_message(segments.first), request))
        else
          not_found
        end
      rescue Errno::ENOENT, Mail::Field::ParseError, Mail::UnknownEncodingType
        not_found
      end

      private

      def production?
        @environment.respond_to?(:production?) ? @environment.production? : @environment.to_s == "production"
      end

      def authorized?(request)
        return @authorized.call(request) if @authorized

        test? || ["127.0.0.1", "::1"].include?(request.env["REMOTE_ADDR"].to_s)
      end

      def test?
        @environment.respond_to?(:test?) ? @environment.test? : @environment.to_s == "test"
      end

      def index_page(request)
        rows = message_paths.map do |path|
          mail = Mail.read(path)
          id = File.basename(path)
          <<~HTML
            <tr>
              <td><a href="#{escape(request.script_name)}/#{escape(id)}">#{escape(mail.subject.to_s.empty? ? "(no subject)" : mail.subject)}</a></td>
              <td>#{escape(Array(mail.to).join(", "))}</td>
              <td>#{escape(mail.date || File.mtime(path).utc)}</td>
            </tr>
          HTML
        rescue Mail::Field::ParseError, Mail::UnknownEncodingType
          ""
        end.join

        content = if rows.empty?
          "<section><h2>No messages</h2><p>Development mail will appear here after delivery.</p></section>"
        else
          <<~HTML
            <section>
              <table>
                <thead><tr><th>Subject</th><th>To</th><th>Delivered</th></tr></thead>
                <tbody>#{rows}</tbody>
              </table>
            </section>
          HTML
        end
        page("Hacienda Mail", content)
      end

      def message_page(message, request)
        mail = message.fetch(:mail)
        text = text_body(mail)
        html = html_body(mail)
        links = extract_links(mail)
        metadata = [
          ["From", Array(mail.from).join(", ")],
          ["To", Array(mail.to).join(", ")],
          ["Subject", mail.subject],
          ["Date", mail.date]
        ].map { |name, value| "<dt>#{escape(name)}</dt><dd>#{escape(value)}</dd>" }.join
        sections = [
          %(<p><a href="#{escape(request.script_name)}/">Back to inbox</a></p>),
          "<section><dl>#{metadata}</dl></section>"
        ]
        sections << "<section><h2>Text</h2><pre>#{escape(text)}</pre></section>" unless text.empty?
        unless html.empty?
          safe_html = <<~HTML
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
            #{html}
          HTML
          sections << <<~HTML
            <section>
              <h2>HTML</h2>
              <iframe sandbox title="HTML email preview" srcdoc="#{escape(safe_html)}"></iframe>
            </section>
          HTML
        end
        unless links.empty?
          items = links.map do |url|
            escaped = escape(url)
            %(<li><a href="#{escaped}" target="_blank" rel="noreferrer noopener">#{escaped}</a></li>)
          end.join
          sections << "<section><h2>Links</h2><ul class=\"links\">#{items}</ul></section>"
        end
        sections << "<details><summary>Raw message</summary><pre>#{escape(message.fetch(:raw))}</pre></details>"
        page(mail.subject.to_s.empty? ? "Message" : mail.subject, sections.join)
      end

      def message_paths
        Dir[File.join(mail_directory, "*.eml")].select { |path| regular_message_file?(path) }.sort.reverse
      end

      def load_message(id)
        raise Errno::ENOENT unless MESSAGE_ID.match?(id.to_s)

        path = File.join(mail_directory, id)
        raise Errno::ENOENT unless regular_message_file?(path)

        raw = File.binread(path)
        {mail: Mail.read_from_string(raw), raw:}
      end

      def regular_message_file?(path)
        File.lstat(path).file?
      rescue Errno::ENOENT
        false
      end

      def mail_directory
        File.join(@root, "tmp", "mail")
      end

      def text_body(mail)
        part = mail.multipart? ? mail.text_part : (mail.mime_type == "text/plain" ? mail : nil)
        decoded_body(part)
      end

      def html_body(mail)
        part = mail.multipart? ? mail.html_part : (mail.mime_type == "text/html" ? mail : nil)
        decoded_body(part)
      end

      def decoded_body(part)
        part ? part.decoded.to_s.encode("UTF-8", invalid: :replace, undef: :replace) : ""
      end

      def extract_links(mail)
        source = [text_body(mail), html_body(mail)].join("\n")
        pattern = URI::RFC2396_PARSER.make_regexp(%w[http https])
        source.to_enum(:scan, pattern)
          .map { Regexp.last_match(0).sub(/[\s<>'\"]+\z/, "") }
          .uniq
          .first(MAX_LINKS)
      end

      def page(title, content)
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{escape(title)}</title>
            <style>
              body { margin: 0; color: #171715; background: #f3f3ef; font: 16px/1.5 system-ui, sans-serif; }
              header { padding: 1rem 1.25rem; background: #171715; color: #fff; }
              main { width: min(70rem, calc(100% - 2rem)); margin: 0 auto; padding: 1.5rem 0 3rem; }
              section, details { margin-bottom: 1rem; border: 1px solid #c9c9c2; background: #fff; padding: 1rem; }
              h1, h2 { margin-top: 0; letter-spacing: 0; }
              table { width: 100%; border-collapse: collapse; }
              th, td { border-bottom: 1px solid #ddd; padding: .65rem; text-align: left; vertical-align: top; }
              dl { display: grid; grid-template-columns: 6rem 1fr; gap: .5rem; margin: 0; }
              dt { font-weight: 700; } dd { margin: 0; }
              pre { overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
              iframe { width: 100%; min-height: 28rem; border: 1px solid #bbb; background: #fff; }
              .links { overflow-wrap: anywhere; }
            </style>
          </head>
          <body><header><h1>#{escape(title)}</h1></header><main>#{content}</main></body>
          </html>
        HTML
      end

      def html_response(body)
        [
          200,
          {
            "content-type" => "text/html; charset=utf-8",
            "cache-control" => "no-store",
            "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; frame-src 'self'; base-uri 'none'; form-action 'none'"
          },
          [body]
        ]
      end

      def forbidden
        [403, {"content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store"}, ["Forbidden"]]
      end

      def not_found
        [404, {"content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store"}, ["Not Found"]]
      end

      def escape(value)
        ERB::Util.html_escape(value.to_s)
      end
    end
  end
end
