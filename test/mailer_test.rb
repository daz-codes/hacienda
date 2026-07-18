# frozen_string_literal: true

require_relative "test_helper"

class MailerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("lunula-mail")
    Lunula.clear_mail_deliveries
    Lunula.clear_enqueued_jobs
    Lunula.configure_jobs(adapter: :inline)
    Lunula.configure_mail(
      root: @root,
      delivery: :test,
      from: "hello@example.test"
    )
  end

  def teardown
    Lunula.clear_mail_deliveries
    Lunula.clear_enqueued_jobs
    Lunula.configure_jobs(adapter: :inline)
    FileUtils.rm_rf(@root)
  end

  def test_mail_can_be_delivered_to_test_adapter
    Lunula.mail(
      to: "reader@example.com",
      subject: "Welcome",
      text: "Hello from Lunula"
    ).deliver

    assert_equal 1, Lunula.mail_deliveries.length
    delivered = Lunula.mail_deliveries.first
    assert_equal ["reader@example.com"], delivered.to
    assert_equal ["hello@example.test"], delivered.from
    assert_equal "Welcome", delivered.subject
    assert_includes delivered.body.decoded, "Hello from Lunula"
  end

  def test_mail_can_generate_multipart_messages
    message = Lunula.mail(
      to: "reader@example.com",
      subject: "Both formats",
      text: "Plain content",
      html: "<strong>HTML content</strong>"
    )

    assert message.mail.multipart?
    assert_includes message.encoded, "Plain content"
    assert_includes message.encoded, "<strong>HTML content</strong>"
  end

  def test_file_delivery_writes_eml_files
    Lunula.configure_mail(root: @root, delivery: :file)

    Lunula.mail(
      to: "reader@example.com",
      subject: "Saved",
      text: "Written to disk"
    ).deliver

    files = Dir[File.join(@root, "tmp", "mail", "*.eml")]
    assert_equal 1, files.length
    assert_includes File.read(files.first), "Written to disk"
  end

  def test_mail_can_be_delivered_later
    Lunula.configure_jobs(adapter: :test)

    Lunula.mail(
      to: "reader@example.com",
      subject: "Queued",
      text: "Queued mail"
    ).deliver_later

    assert_empty Lunula.mail_deliveries
    assert_equal 1, Lunula.enqueued_jobs.length

    Lunula.perform_enqueued_jobs

    assert_equal 1, Lunula.mail_deliveries.length
    assert_equal "Queued", Lunula.mail_deliveries.first.subject
  end

  def test_unknown_delivery_adapter_raises_a_clear_error
    Lunula.configure_mail(delivery: :carrier_pigeon)

    error = assert_raises(Lunula::Mailer::Error) do
      Lunula.mail(to: "reader@example.com", subject: "Nope", text: "Nope").deliver
    end

    assert_includes error.message, "unknown mail delivery adapter"
  end

  def test_development_inbox_lists_and_safely_previews_file_deliveries
    Lunula.configure_mail(root: @root, delivery: :file)
    Lunula.mail(
      to: "reader@example.com",
      subject: "Sign in <now>",
      text: "Open http://example.test/magic-login?token=secret",
      html: %(<h1>Welcome</h1><script>alert("unsafe")</script>)
    ).deliver
    id = File.basename(Dir[File.join(@root, "tmp", "mail", "*.eml")].fetch(0))
    request = Rack::MockRequest.new(
      Lunula::Mailer::Inbox.new(root: @root, environment: "development")
    )

    index = request.get("/", "REMOTE_ADDR" => "127.0.0.1")
    message = request.get("/#{id}", "REMOTE_ADDR" => "127.0.0.1")

    assert_equal 200, index.status
    assert_includes index.body, "Sign in &lt;now&gt;"
    assert_includes index.body, id
    assert_includes index.body, %(href="/#{id}")
    assert_equal 200, message.status
    assert_includes message.body, "sandbox"
    assert_includes message.body, "&lt;script&gt;alert"
    refute_includes message.body, %(<script>alert)
    assert_includes message.body, "http://example.test/magic-login?token=secret"
    assert_includes message.body, "Raw message"
    assert_includes message["content-security-policy"], "default-src 'none'"
  end

  def test_development_inbox_rejects_remote_and_invalid_message_requests
    inbox = Lunula::Mailer::Inbox.new(root: @root, environment: "development")
    request = Rack::MockRequest.new(inbox)

    assert_equal 403, request.get("/", "REMOTE_ADDR" => "203.0.113.10").status
    assert_equal 404, request.get("/../config/credentials.yml.enc", "REMOTE_ADDR" => "127.0.0.1").status
    assert_equal 404, request.get("/not-a-message.eml", "REMOTE_ADDR" => "127.0.0.1").status
  end

  def test_development_inbox_is_unavailable_in_production
    inbox = Lunula::Mailer::Inbox.new(
      root: @root,
      environment: "production",
      authorized: ->(_request) { true }
    )

    assert_equal 404, Rack::MockRequest.new(inbox).get("/", "REMOTE_ADDR" => "127.0.0.1").status
  end
end
