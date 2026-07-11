# frozen_string_literal: true

require_relative "test_helper"

class MailerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("hacienda-mail")
    Hacienda.clear_mail_deliveries
    Hacienda.clear_enqueued_jobs
    Hacienda.configure_jobs(adapter: :inline)
    Hacienda.configure_mail(
      root: @root,
      delivery: :test,
      from: "hello@example.test"
    )
  end

  def teardown
    Hacienda.clear_mail_deliveries
    Hacienda.clear_enqueued_jobs
    Hacienda.configure_jobs(adapter: :inline)
    FileUtils.rm_rf(@root)
  end

  def test_mail_can_be_delivered_to_test_adapter
    Hacienda.mail(
      to: "reader@example.com",
      subject: "Welcome",
      text: "Hello from Hacienda"
    ).deliver

    assert_equal 1, Hacienda.mail_deliveries.length
    delivered = Hacienda.mail_deliveries.first
    assert_equal ["reader@example.com"], delivered.to
    assert_equal ["hello@example.test"], delivered.from
    assert_equal "Welcome", delivered.subject
    assert_includes delivered.body.decoded, "Hello from Hacienda"
  end

  def test_mail_can_generate_multipart_messages
    message = Hacienda.mail(
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
    Hacienda.configure_mail(root: @root, delivery: :file)

    Hacienda.mail(
      to: "reader@example.com",
      subject: "Saved",
      text: "Written to disk"
    ).deliver

    files = Dir[File.join(@root, "tmp", "mail", "*.eml")]
    assert_equal 1, files.length
    assert_includes File.read(files.first), "Written to disk"
  end

  def test_mail_can_be_delivered_later
    Hacienda.configure_jobs(adapter: :test)

    Hacienda.mail(
      to: "reader@example.com",
      subject: "Queued",
      text: "Queued mail"
    ).deliver_later

    assert_empty Hacienda.mail_deliveries
    assert_equal 1, Hacienda.enqueued_jobs.length

    Hacienda.perform_enqueued_jobs

    assert_equal 1, Hacienda.mail_deliveries.length
    assert_equal "Queued", Hacienda.mail_deliveries.first.subject
  end

  def test_unknown_delivery_adapter_raises_a_clear_error
    Hacienda.configure_mail(delivery: :carrier_pigeon)

    error = assert_raises(Hacienda::Mailer::Error) do
      Hacienda.mail(to: "reader@example.com", subject: "Nope", text: "Nope").deliver
    end

    assert_includes error.message, "unknown mail delivery adapter"
  end
end
