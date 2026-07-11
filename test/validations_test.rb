# frozen_string_literal: true

require_relative "test_helper"

class ValidationsTest < Minitest::Test
  class Post
    include Hacienda::Validations

    attr_accessor :title

    def initialize(title: "")
      @title = title
    end

    def validate
      errors.add :title, "is required" if title.to_s.strip.empty?
    end
  end

  class Account
    include Hacienda::Validations

    def validate(password:)
      errors.add :password, "must be at least 12 characters" if password.length < 12
    end
  end

  class Legacy
    include Hacienda::Validations

    def validate
      ["Name is required"]
    end
  end

  class MixedStyle
    include Hacienda::Validations

    def validate
      errors.add :name, "is required"
      ["This return value is incidental"]
    end
  end

  class AccidentalHash
    include Hacienda::Validations

    def validate
      {checked: true}
    end
  end

  def test_valid_runs_validate_and_collects_full_messages
    post = Post.new

    refute post.valid?
    assert_equal ["Title is required"], post.errors.to_a
    assert_equal ["is required"], post.errors[:title]
  end

  def test_errors_are_cleared_before_each_validation_run
    post = Post.new

    refute post.valid?
    post.title = "Explicit Ruby"

    assert post.valid?
    assert_empty post.errors.to_a
  end

  def test_valid_accepts_keyword_arguments
    account = Account.new

    refute account.valid?(password: "short")
    assert_equal ["Password must be at least 12 characters"], account.errors.to_a
  end

  def test_legacy_validate_arrays_are_imported
    legacy = Legacy.new

    refute legacy.valid?
    assert_equal ["Name is required"], legacy.errors.to_a
  end

  def test_returned_messages_are_not_imported_after_errors_were_added
    record = MixedStyle.new

    refute record.valid?
    assert_equal ["Name is required"], record.errors.to_a
  end

  def test_arbitrary_enumerables_are_not_treated_as_errors
    record = AccidentalHash.new

    assert record.valid?
    assert_empty record.errors.to_a
  end
end
