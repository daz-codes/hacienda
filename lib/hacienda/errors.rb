# frozen_string_literal: true

require "erb"

module Hacienda
  module Errors
    module_function

    def render(error)
      Hacienda.env.development? ? development_error(error) : production_error
    end

    def development_error(error)
      escaped_message = ERB::Util.html_escape("#{error.class}: #{error.message}")
      escaped_backtrace = ERB::Util.html_escape(Array(error.backtrace).join("\n"))

      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Application Error</title>
            <style>
              :root { color-scheme: light dark; font-family: ui-sans-serif, system-ui, sans-serif; }
              body { max-width: 72rem; margin: 0 auto; padding: 3rem 1.5rem; line-height: 1.5; }
              h1 { color: #d36f3d; }
              pre { overflow: auto; padding: 1rem; border: 1px solid color-mix(in srgb, currentColor 20%, transparent); border-radius: .75rem; }
            </style>
          </head>
          <body>
            <h1>Application error</h1>
            <h2>#{escaped_message}</h2>
            <pre>#{escaped_backtrace}</pre>
          </body>
        </html>
      HTML
    end

    def production_error
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Application Error</title>
          </head>
          <body>
            <h1>Something went wrong</h1>
            <p>The application could not complete this request.</p>
          </body>
        </html>
      HTML
    end
  end
end
