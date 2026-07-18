# frozen_string_literal: true

require_relative "test_helper"

class FlashTest < Minitest::Test
  def test_flash_now_normalizes_symbol_keys
    flash = Lunula::Flash.new({})

    flash.now[:notice] = "Saved"

    assert_equal "Saved", flash[:notice]
    assert_equal "Saved", flash.now["notice"]
    assert_equal({"notice" => "Saved"}, flash.now.to_h)
  end

  def test_flash_now_is_not_written_to_the_session
    session = {}
    flash = Lunula::Flash.new(session)

    flash.now[:notice] = "Current request only"

    assert_empty session
  end
end
