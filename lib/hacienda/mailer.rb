# frozen_string_literal: true

require "fileutils"
require "securerandom"

begin
  previous_verbose = $VERBOSE
  $VERBOSE = nil
  require "mail"
  require "mail/parsers/address_lists_parser"
  require "mail/parsers/content_type_parser"
  require "mail/parsers/date_time_parser"
  require "mail/parsers/message_ids_parser"
ensure
  $VERBOSE = previous_verbose
end

module Hacienda
  module Mailer
    class Error < Hacienda::Error; end

    class Configuration
      attr_accessor :delivery, :from, :root, :smtp

      def initialize(root: nil, delivery: :file, from: "no-reply@example.test", smtp: {})
        @root = root
        @delivery = delivery
        @from = from
        @smtp = smtp
      end

      def adapter
        case delivery.to_s
        when "file"
          FileDelivery.new(root:)
        when "smtp"
          SMTPDelivery.new(settings: smtp)
        when "test"
          TestDelivery
        else
          raise Error, "unknown mail delivery adapter: #{delivery.inspect}"
        end
      end
    end

    class Message
      attr_reader :mail, :delivery

      def initialize(mail, delivery:)
        @mail = mail
        @delivery = delivery
      end

      def deliver
        delivery.deliver(mail)
        self
      end

      def deliver_later
        Hacienda.enqueue(DeliverMessageJob, encoded)
        self
      end

      def encoded
        mail.encoded
      end

      def to_s
        encoded
      end
    end

    module DeliverMessageJob
      module_function

      def perform(encoded_message)
        mail = ::Mail.read_from_string(encoded_message)
        Hacienda.mail_config.adapter.deliver(mail)
      end
    end

    class FileDelivery
      attr_reader :root

      def initialize(root:)
        @root = root
      end

      def deliver(mail)
        raise Error, "mail file delivery requires Hacienda.root" unless root

        FileUtils.mkdir_p(directory)
        path = File.join(directory, filename)
        File.write(path, mail.encoded)
        path
      end

      private

      def directory
        File.join(root, "tmp", "mail")
      end

      def filename
        timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S%6N")
        "#{timestamp}-#{SecureRandom.hex(4)}.eml"
      end
    end

    class SMTPDelivery
      attr_reader :settings

      def initialize(settings:)
        @settings = settings
      end

      def deliver(mail)
        mail.delivery_method(:smtp, settings)
        mail.deliver!
      end
    end

    module TestDelivery
      module_function

      def deliver(mail)
        deliveries << mail
      end

      def deliveries
        @deliveries ||= []
      end

      def clear
        deliveries.clear
      end
    end

    module_function

    def build(config, to:, subject:, text: nil, html: nil, from: nil, **headers)
      raise Error, "mail requires text or html content" if text.nil? && html.nil?

      mail = ::Mail.new
      mail.to = Array(to)
      mail.from = from || config.from
      mail.subject = subject
      headers.each { |name, value| mail[header_name(name)] = value }

      assign_body(mail, text:, html:)

      Message.new(mail, delivery: config.adapter)
    end

    def assign_body(mail, text:, html:)
      if text && html
        mail.text_part = ::Mail::Part.new do
          content_type "text/plain; charset=UTF-8"
          body text
        end
        mail.html_part = ::Mail::Part.new do
          content_type "text/html; charset=UTF-8"
          body html
        end
      elsif html
        mail.content_type = "text/html; charset=UTF-8"
        mail.body = html
      else
        mail.content_type = "text/plain; charset=UTF-8"
        mail.body = text
      end
    end

    def header_name(name)
      name.to_s.tr("_", "-")
    end
  end
end
