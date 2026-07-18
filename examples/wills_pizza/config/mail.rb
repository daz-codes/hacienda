# frozen_string_literal: true

mail_delivery = ENV.fetch(
  "LUNULA_MAIL_DELIVERY",
  Lunula.env.test? ? "test" : Lunula.env.production? ? "smtp" : "file"
)
mail_credentials = File.file?(File.join(APP_ROOT, "config", "credentials.yml.enc")) ? Lunula.credentials : {}

Lunula.configure_mail(
  root: APP_ROOT,
  delivery: mail_delivery.to_sym,
  from: ENV.fetch("LUNULA_MAIL_FROM", "hello@example.test"),
  smtp: {
    address: ENV["SMTP_ADDRESS"] || mail_credentials.dig(:mail, :smtp_address),
    port: (ENV["SMTP_PORT"] || mail_credentials.dig(:mail, :smtp_port) || 587).to_i,
    user_name: ENV["SMTP_USERNAME"] || mail_credentials.dig(:mail, :smtp_username),
    password: ENV["SMTP_PASSWORD"] || mail_credentials.dig(:mail, :smtp_password),
    authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain"),
    enable_starttls_auto: ENV.fetch("SMTP_STARTTLS", "true") != "false"
  }.compact
)
