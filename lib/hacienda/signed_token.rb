# frozen_string_literal: true

require "base64"
require "json"
require "openssl"

module Hacienda
  class SignedToken
    class Error < Hacienda::Error; end

    DIGEST = "SHA256"

    attr_reader :secret, :old_secrets

    # New tokens are always signed with `secret`; `old_secrets` are only used
    # to verify, so rotating a secret doesn't invalidate outstanding tokens.
    def initialize(secret:, old_secrets: [])
      @secret = secret.to_s
      @old_secrets = Array(old_secrets).map(&:to_s).reject(&:empty?).freeze
      raise Error, "signed token secret is required" if @secret.empty?
    end

    def generate(payload, purpose:, expires_in: nil)
      envelope = {
        "payload" => stringify_keys(payload),
        "purpose" => purpose.to_s,
        "expires_at" => expires_in ? Time.now.to_i + expires_in.to_i : nil
      }
      data = encode(JSON.generate(envelope))
      signature = sign(data)

      "#{data}.#{signature}"
    end

    def verify(token, purpose:)
      data, signature = token.to_s.split(".", 2)
      return unless data && signature
      return unless [secret, *old_secrets].any? { |candidate| secure_compare(signature, sign(data, candidate)) }

      envelope = JSON.parse(decode(data))
      return unless envelope["purpose"] == purpose.to_s
      return if envelope["expires_at"] && Time.now.to_i > envelope["expires_at"].to_i

      envelope["payload"]
    rescue JSON::ParserError, ArgumentError
      nil
    end

    private

    def sign(data, key = secret)
      encode(OpenSSL::HMAC.digest(DIGEST, key, data))
    end

    def encode(value)
      Base64.urlsafe_encode64(value, padding: false)
    end

    def decode(value)
      Base64.urlsafe_decode64(value)
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, nested), result| result[key.to_s] = stringify_keys(nested) }
      when Array
        value.map { |nested| stringify_keys(nested) }
      else
        value
      end
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) { |result, (a, b)| result | (a ^ b) }.zero?
    end
  end
end
