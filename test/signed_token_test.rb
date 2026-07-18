# frozen_string_literal: true

require_relative "test_helper"

class SignedTokenTest < Minitest::Test
  def setup
    @tokens = Lunula::SignedToken.new(secret: "test-secret")
  end

  def test_generates_and_verifies_payload_for_a_purpose
    token = @tokens.generate({user_id: 42}, purpose: "email_verification", expires_in: 60)

    payload = @tokens.verify(token, purpose: "email_verification")

    assert_equal 42, payload["user_id"]
  end

  def test_rejects_wrong_purpose
    token = @tokens.generate({user_id: 42}, purpose: "email_verification", expires_in: 60)

    assert_nil @tokens.verify(token, purpose: "password_reset")
  end

  def test_rejects_tampered_tokens
    token = @tokens.generate({user_id: 42}, purpose: "email_verification", expires_in: 60)

    assert_nil @tokens.verify("#{token}x", purpose: "email_verification")
  end

  def test_rejects_expired_tokens
    token = @tokens.generate({user_id: 42}, purpose: "email_verification", expires_in: -1)

    assert_nil @tokens.verify(token, purpose: "email_verification")
  end

  def test_verifies_tokens_signed_with_an_old_secret_after_rotation
    token = @tokens.generate({user_id: 42}, purpose: "email_verification", expires_in: 60)
    rotated = Lunula::SignedToken.new(secret: "new-secret", old_secrets: ["test-secret"])

    payload = rotated.verify(token, purpose: "email_verification")

    assert_equal 42, payload["user_id"]
  end

  def test_signs_new_tokens_with_the_current_secret_only
    rotated = Lunula::SignedToken.new(secret: "new-secret", old_secrets: ["test-secret"])
    token = rotated.generate({user_id: 42}, purpose: "email_verification", expires_in: 60)

    assert_equal 42, rotated.verify(token, purpose: "email_verification")["user_id"]
    assert_nil @tokens.verify(token, purpose: "email_verification")
  end

  def test_rejects_tokens_signed_with_an_unknown_secret
    token = Lunula::SignedToken.new(secret: "other-secret")
      .generate({user_id: 42}, purpose: "email_verification", expires_in: 60)
    rotated = Lunula::SignedToken.new(secret: "new-secret", old_secrets: ["test-secret"])

    assert_nil rotated.verify(token, purpose: "email_verification")
  end
end
