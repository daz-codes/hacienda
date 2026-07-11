# frozen_string_literal: true

require "rack/utils"

module Products
  module Mailer
    module_function

    def in_stock(product:, subscriber:)
      product_url = Hacienda.app_url("/products/#{Rack::Utils.escape_path(product.id.to_s)}")
      unsubscribe_url = Hacienda.app_url("/unsubscribe?#{Rack::Utils.build_query(token: unsubscribe_token(subscriber))}")
      name = Hacienda::HTML.escape(product.name)

      Hacienda.mail(
        to: subscriber.email,
        subject: "#{product.name} is back in stock",
        text: <<~TEXT,
          Good news!

          #{product.name} is back in stock.
          #{product_url}

          Unsubscribe: #{unsubscribe_url}
        TEXT
        html: <<~HTML
          <h1>Good news!</h1>
          <p><a href="#{product_url}">#{name}</a> is back in stock.</p>
          <p><a href="#{unsubscribe_url}">Unsubscribe</a></p>
        HTML
      )
    end

    def unsubscribe_token(subscriber)
      Hacienda.signed_token.generate(
        {subscriber_id: subscriber.id, email: subscriber.email},
        purpose: "product_unsubscribe",
        expires_in: 30 * 24 * 60 * 60
      )
    end
  end
end
