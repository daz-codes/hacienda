# frozen_string_literal: true

require_relative "test_helper"

class CredentialsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("hacienda-credentials")
    @credentials = Hacienda::Credentials.new(root: @directory).ensure_files
    @credentials.write_text("mail:\n  password: secret\n")
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def test_rotate_re_encrypts_with_a_new_master_key
    old_key = File.read(@credentials.master_key_path).strip
    old_ciphertext = File.read(@credentials.encrypted_path)

    new_key = @credentials.rotate

    refute_equal old_key, new_key
    assert_equal "#{new_key}\n", File.read(@credentials.master_key_path)
    refute_equal old_ciphertext, File.read(@credentials.encrypted_path)
    assert_equal "secret", @credentials.dig(:mail, :password)
    assert_equal "secret", Hacienda::Credentials.new(root: @directory).dig(:mail, :password)
  end

  def test_master_key_is_created_with_owner_only_permissions
    assert_equal 0o600, File.stat(@credentials.master_key_path).mode & 0o777
  end

  def test_rotate_preserves_owner_only_master_key_permissions
    @credentials.rotate

    assert_equal 0o600, File.stat(@credentials.master_key_path).mode & 0o777
  end

  def test_rotate_accepts_an_explicit_key
    new_key = Hacienda::Credentials.generate_key

    assert_equal new_key, @credentials.rotate(new_key: new_key)
    assert_equal "secret", Hacienda::Credentials.new(root: @directory).dig(:mail, :password)
  end

  def test_rotate_validates_the_new_key
    assert_raises(Hacienda::Credentials::Error) { @credentials.rotate(new_key: "not-hex") }
  end

  def test_rotate_refuses_while_the_env_master_key_is_set
    ENV["HACIENDA_MASTER_KEY"] = Hacienda::Credentials.generate_key

    error = assert_raises(Hacienda::Credentials::Error) { @credentials.rotate }

    assert_includes error.message, "HACIENDA_MASTER_KEY"
  ensure
    ENV.delete("HACIENDA_MASTER_KEY")
  end
end
