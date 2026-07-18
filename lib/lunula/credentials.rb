# frozen_string_literal: true

require "base64"
require "fileutils"
require "openssl"
require "securerandom"
require "yaml"

module Lunula
  class Credentials
    class Error < Lunula::Error; end

    CIPHER = "aes-256-gcm"
    KEY_SIZE = 32
    KEY_HEX_SIZE = KEY_SIZE * 2
    VERSION = "v1"
    AUTH_DATA = "Lunula::Credentials.v1"

    attr_reader :root

    def self.generate_key
      SecureRandom.hex(KEY_SIZE)
    end

    def initialize(root:)
      @root = File.expand_path(root)
      @data = nil
    end

    def [](key)
      data[key.to_s]
    end

    def fetch(key, ...)
      data.fetch(key.to_s, ...)
    end

    def dig(*keys)
      keys.map!(&:to_s)
      data.dig(*keys)
    end

    def to_h
      data.dup
    end

    def available?
      File.file?(encrypted_path) && (
        !ENV["LUNULA_MASTER_KEY"].to_s.strip.empty? || File.file?(master_key_path)
      )
    end

    def read_text
      return "{}\n" unless File.file?(encrypted_path)

      decrypt(File.read(encrypted_path))
    end

    def write_text(text)
      FileUtils.mkdir_p(File.dirname(encrypted_path))
      File.write(encrypted_path, encrypt(text))
      @data = nil
    end

    # Re-encrypts the credentials with a fresh master key and writes it to
    # config/master.key. Refuses to run while LUNULA_MASTER_KEY is set,
    # because the env var would keep overriding the rotated file.
    def rotate(new_key: self.class.generate_key)
      if ENV["LUNULA_MASTER_KEY"]
        raise Error, "unset LUNULA_MASTER_KEY before rotating; it would override the new config/master.key"
      end

      new_key = validate_key(new_key)
      plaintext = read_text

      FileUtils.mkdir_p(File.dirname(master_key_path))
      File.write(master_key_path, "#{new_key}\n")
      File.chmod(0o600, master_key_path)
      File.write(encrypted_path, encrypt(plaintext, key: [new_key].pack("H*")))
      @data = nil

      new_key
    end

    def ensure_files(default: "{}\n")
      FileUtils.mkdir_p(File.dirname(master_key_path))
      File.write(master_key_path, "#{self.class.generate_key}\n") unless File.file?(master_key_path)
      File.chmod(0o600, master_key_path)
      write_text(default) unless File.file?(encrypted_path)
      self
    end

    def encrypted_path
      File.join(root, "config", "credentials.yml.enc")
    end

    def master_key_path
      File.join(root, "config", "master.key")
    end

    private

    def data
      @data ||= begin
        loaded = YAML.safe_load(read_text, permitted_classes: [], permitted_symbols: [], aliases: false)
        stringify_keys(loaded || {})
      end
    rescue Psych::SyntaxError => error
      raise Error, "invalid credentials YAML: #{error.message}"
    end

    def encrypt(plaintext, key: self.key)
      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.encrypt
      cipher.key = key
      iv = SecureRandom.random_bytes(12)
      cipher.iv = iv
      cipher.auth_data = AUTH_DATA

      ciphertext = cipher.update(plaintext.to_s) + cipher.final
      [
        VERSION,
        Base64.strict_encode64(iv),
        Base64.strict_encode64(cipher.auth_tag),
        Base64.strict_encode64(ciphertext)
      ].join(":")
    end

    def decrypt(payload)
      version, encoded_iv, encoded_tag, encoded_ciphertext = payload.to_s.strip.split(":", 4)
      raise Error, "unsupported credentials format" unless version == VERSION

      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.decrypt
      cipher.key = key
      cipher.iv = Base64.strict_decode64(encoded_iv)
      cipher.auth_tag = Base64.strict_decode64(encoded_tag)
      cipher.auth_data = AUTH_DATA
      cipher.update(Base64.strict_decode64(encoded_ciphertext)) + cipher.final
    rescue ArgumentError, OpenSSL::Cipher::CipherError
      raise Error, "could not decrypt credentials"
    end

    def key
      value = validate_key(ENV["LUNULA_MASTER_KEY"] || read_master_key)

      [value].pack("H*")
    end

    def validate_key(value)
      value = value.to_s.strip
      unless value.match?(/\A[0-9a-fA-F]{#{KEY_HEX_SIZE}}\z/)
        raise Error, "invalid master key; expected #{KEY_HEX_SIZE} hex characters"
      end

      value
    end

    def read_master_key
      raise Error, "missing config/master.key or LUNULA_MASTER_KEY" unless File.file?(master_key_path)

      File.read(master_key_path)
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, nested), result|
          result[key.to_s] = stringify_keys(nested)
        end
      when Array
        value.map { |nested| stringify_keys(nested) }
      else
        value
      end
    end
  end
end
