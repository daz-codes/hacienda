# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "bcrypt"
require "rack"
require "rack/test"
require "sequel"
require "sequel/extensions/migration"
require "tempfile"
require "tmpdir"
require "fileutils"

BLOG_ROOT = File.expand_path("../..", __dir__)
test_database_directory = unless ENV["DATABASE_URL"]
  Dir.mktmpdir("lunula-blog-test").tap do |directory|
    ENV["DATABASE_URL"] = "sqlite://#{File.join(directory, "test.sqlite3")}"
  end
end
BLOG_APP = Rack::Builder.parse_file(File.join(BLOG_ROOT, "config.ru"))

Minitest.after_run do
  DB.disconnect
  FileUtils.rm_rf(test_database_directory) if test_database_directory
end

Sequel::Migrator.run(DB, File.join(BLOG_ROOT, "db", "migrations"))

class BlogTest < Minitest::Test
  include Rack::Test::Methods

  def app
    BLOG_APP
  end

  def setup
    DB[:comments].delete
    DB[:posts].delete
    DB[:users].delete
    Lunula.clear_mail_deliveries
    clear_cookies
  end

  def test_author_can_create_publish_and_archive_a_post
    recorder = Lunula::Events::Recorder.new
    published_subscription = APP.events.subscribe(Posts::Events::Published, recorder)
    archived_subscription = APP.events.subscribe(Posts::Events::Archived, recorder)
    signup

    get "/posts/new"
    assert_equal 200, last_response.status

    post "/posts", {
      _csrf: csrf_token,
      title: "Explicit Ruby",
      body: "A post built from a domain object."
    }
    assert_equal 303, last_response.status

    location = last_response["location"]
    get location
    assert_includes last_response.body, "Draft"

    post "#{location}/publish", {_csrf: csrf_token}
    assert_equal 303, last_response.status
    assert_instance_of Posts::Events::Published, recorder.events.last

    clear_cookies
    get "/posts"
    assert_includes last_response.body, "Explicit Ruby"

    signup(email: "second@example.com")
    post "#{location}/archive", {_csrf: csrf_token}
    assert_equal 403, last_response.status
    assert_equal 1, recorder.events.length
  ensure
    APP.events.unsubscribe(published_subscription) if published_subscription
    APP.events.unsubscribe(archived_subscription) if archived_subscription
  end

  def test_csrf_protection_rejects_unsafe_requests_without_a_token
    post "/signup", {email: "writer@example.com", password: "long-enough-password"}

    assert_equal 403, last_response.status
  end

  def test_owner_archiving_emits_an_event_after_commit
    recorder = Lunula::Events::Recorder.new
    subscription = APP.events.subscribe(Posts::Events::Archived, recorder)
    signup

    get "/posts/new"
    post "/posts", {
      _csrf: csrf_token,
      title: "Eventful Ruby",
      body: "Events should follow committed changes."
    }
    location = last_response["location"]

    post "#{location}/archive", {_csrf: csrf_token}

    assert_equal 303, last_response.status
    event = recorder.events.last
    assert_instance_of Posts::Events::Archived, event
    assert_equal DB[:posts].first[:id], event.post_id
    refute_nil DB[:posts].first[:archived_at]
  ensure
    APP.events.unsubscribe(subscription) if subscription
  end

  def test_unverified_login_uses_neutral_error
    get "/signup"
    post "/signup", {
      _csrf: csrf_token,
      email: "unverified@example.com",
      password: "long-enough-password"
    }
    assert_equal 303, last_response.status
    clear_cookies

    get "/login"
    post "/login", {
      _csrf: csrf_token,
      email: "unverified@example.com",
      password: "long-enough-password"
    }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Invalid email or password"
    refute_includes last_response.body, "Verify your email"
  end

  def test_password_verification_performs_one_bcrypt_check_for_known_and_unknown_accounts
    user = Struct.new(:password_digest).new(BCrypt::Password.create("known-password").to_s)
    verifier = Class.new do
      class << self
        attr_accessor :checked_digests

        def valid_hash?(digest)
          digest.start_with?("$2a$")
        end

        def new(digest)
          self.checked_digests ||= []
          checked_digests << digest
          allocate
        end
      end

      def ==(_value)
        false
      end
    end

    refute Auth::PasswordAuthenticatable.credentials_match?(nil, "guess", password_class: verifier)
    refute Auth::PasswordAuthenticatable.credentials_match?(user, "guess", password_class: verifier)

    assert_equal 2, verifier.checked_digests.length
    assert_equal Auth::PasswordAuthenticatable::DUMMY_PASSWORD_DIGEST, verifier.checked_digests.first
    assert_equal user.password_digest, verifier.checked_digests.last
  end

  def test_login_rotates_the_session_and_csrf_token
    signup
    post "/logout", {_csrf: csrf_token, _method: "delete"}
    clear_cookies

    get "/login"
    previous_csrf = csrf_token
    previous_cookie = rack_mock_session.cookie_jar["lunula.session"]
    post "/login", {
      _csrf: previous_csrf,
      email: "writer@example.com",
      password: "long-enough-password"
    }
    assert_equal 303, last_response.status

    get "/"
    refute_equal previous_cookie, rack_mock_session.cookie_jar["lunula.session"]
    refute_equal previous_csrf, csrf_token
  end

  def test_magic_login_token_is_single_use
    signup
    post "/logout", {_csrf: csrf_token, _method: "delete"}
    clear_cookies

    get "/magic-login"
    post "/magic-login", {_csrf: csrf_token, email: "writer@example.com"}
    assert_equal 303, last_response.status
    token = latest_mail_token

    get "/magic-login/confirm?token=#{token}"
    assert_equal 200, last_response.status
    post "/magic-login/confirm", {_csrf: csrf_token, token:}
    assert_equal 303, last_response.status

    get "/magic-login/confirm?token=#{token}"
    assert_equal 422, last_response.status
    assert_includes last_response.body, "Login link is invalid or expired."
  end

  def test_email_verification_token_is_single_use
    get "/signup"
    post "/signup", {
      _csrf: csrf_token,
      email: "single-use@example.com",
      password: "long-enough-password"
    }
    token = latest_mail_token

    get "/verify-email?token=#{token}"
    post "/verify-email", {_csrf: csrf_token, token:}
    assert_equal 303, last_response.status

    get "/verify-email?token=#{token}"
    assert_equal 422, last_response.status
    assert_includes last_response.body, "Verification link is invalid or expired."
  end

  def test_account_discovery_flows_return_the_same_public_response
    signup
    post "/logout", {_csrf: csrf_token, _method: "delete"}
    clear_cookies

    flows = [
      ["/signup", "/signup", {password: "another-long-password"}],
      ["/login", "/email-verification", {}],
      ["/magic-login", "/magic-login", {}],
      ["/password/forgot", "/password/forgot", {}]
    ]

    flows.each_with_index do |(form_path, submit_path, attributes), index|
      responses = ["writer@example.com", "unknown-#{index}@example.com"].map do |email|
        get form_path
        post submit_path, attributes.merge(_csrf: csrf_token, email:)
        [last_response.status, last_response["location"], last_response.body]
      end

      assert_equal responses.first, responses.last
      assert_equal 303, responses.first.first
      assert_equal "/login", responses.first[1]
    end
  end

  def test_record_authorization_fails_closed
    get "/posts/new"
    assert_equal 303, last_response.status
    assert_equal "/login", last_response["location"]

    signup
    get "/posts/new"
    post "/posts", {_csrf: csrf_token, title: "Private draft", body: "Owned by writer."}
    location = last_response["location"]

    signup(email: "other@example.com")
    post "#{location}/archive", {_csrf: csrf_token}
    assert_equal 403, last_response.status
  end

  def test_password_reset_uses_an_emailed_signed_token
    signup
    post "/logout", {_csrf: csrf_token, _method: "delete"}
    clear_cookies

    get "/password/forgot"
    post "/password/forgot", {
      _csrf: csrf_token,
      email: "writer@example.com"
    }
    assert_equal 303, last_response.status

    token = latest_mail_token
    user = Auth::Repository.find_by_email("writer@example.com")
    refute_includes token, user.password_digest

    get "/password/reset?token=#{token}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Choose a new password"

    patch "/password", {
      _csrf: csrf_token,
      token: token,
      password: "new-long-enough-password"
    }
    assert_equal 303, last_response.status

    get "/password/reset?token=#{token}"
    assert_equal 422, last_response.status

    post "/logout", {_csrf: csrf_token, _method: "delete"}
    clear_cookies

    get "/login"
    post "/login", {
      _csrf: csrf_token,
      email: "writer@example.com",
      password: "new-long-enough-password"
    }
    assert_equal 303, last_response.status
  end

  def test_layout_uses_helium_to_toggle_the_menu
    get "/"

    assert_includes last_response.body, %(@click="menuOpen = !menuOpen")
    assert_includes last_response.body, %(@visible="menuOpen")
    assert_includes last_response.body, %(<link rel="stylesheet" href="/assets/application.css">)

    get "/assets/application.css"
    assert_includes last_response.body, "[hidden]"
  end

  def test_public_posts_use_fragment_and_conditional_http_caching
    signup
    get "/posts/new"
    post "/posts", {
      _csrf: csrf_token,
      title: "Cached Ruby",
      body: "Versioned fragments and validators."
    }
    location = last_response["location"]
    post "#{location}/publish", {_csrf: csrf_token}
    record = Posts::Repository.all.first
    clear_cookies

    get "/posts"
    fragment = APP.cache.read(["fragment", "post-card", record.id, record.updated_at.to_f])
    assert_includes fragment, "Cached Ruby"

    get location
    etag = last_response["etag"]
    assert_match(/\A"[a-f0-9]{64}"\z/, etag)
    assert_equal "public, max-age=60", last_response["cache-control"]

    get location, {}, {"HTTP_IF_NONE_MATCH" => etag}
    assert_equal 304, last_response.status
    assert_equal etag, last_response["etag"]
  end

  def test_author_can_upload_and_serve_a_post_cover
    signup
    image = Tempfile.new(["cover", ".png"])
    image.binmode
    image.write("\x89PNG\r\n\x1a\nexample png bytes".b)
    image.rewind
    upload = Rack::Test::UploadedFile.new(
      image.path,
      "image/png",
      original_filename: "launch.png"
    )
    get "/posts/new"

    post "/posts", {
      _csrf: csrf_token,
      title: "Post with cover",
      body: "Uploaded through Rack multipart params.",
      cover: upload
    }

    assert_equal 303, last_response.status
    record = Posts::Repository.all.first
    assert record.cover?
    assert_equal "launch.png", record.cover_filename
    assert_equal "image/png", record.cover_content_type

    get APP.storage.url(record.cover_key)
    assert_equal 200, last_response.status
    assert_equal "image/png", last_response["content-type"]
    assert_equal "\x89PNG\r\n\x1a\nexample png bytes".b, last_response.body.b
  ensure
    image&.close!
  end

  def test_public_reader_can_comment_on_a_published_post
    signup
    get "/posts/new"
    post "/posts", {
      _csrf: csrf_token,
      title: "Comments in plain Ruby",
      body: "Associations are explicit."
    }
    location = last_response["location"]
    post "#{location}/publish", {_csrf: csrf_token}
    clear_cookies

    get location
    assert_equal 200, last_response.status
    assert_includes last_response.body, "No comments yet."

    post "#{location}/comments", {
      _csrf: csrf_token,
      author_name: "Reader",
      body: "This is loaded explicitly onto post.comments."
    }
    assert_equal 303, last_response.status

    post_record = Posts::Repository.find_with_comments(Posts::Repository.all.first.id)
    assert_equal 1, post_record.comments.length
    assert_equal "Reader", post_record.comments.first.author_name

    get location
    assert_includes last_response.body, "Reader"
    assert_includes last_response.body, "This is loaded explicitly onto post.comments."
  end

  private

  def signup(email: "writer@example.com")
    get "/signup"
    post "/signup", {
      _csrf: csrf_token,
      email: email,
      password: "long-enough-password"
    }
    assert_equal 303, last_response.status
    assert_equal "Verify your email", Lunula.mail_deliveries.last.subject

    get "/verify-email?token=#{latest_mail_token}"
    assert_equal 200, last_response.status
    refute Auth::Repository.find_by_email(email).email_verified?

    post "/verify-email", {
      _csrf: csrf_token,
      token: latest_mail_token
    }
    assert_equal 303, last_response.status
    assert Auth::Repository.find_by_email(email).email_verified?
  end

  def latest_mail_token
    Lunula.mail_deliveries.last.body.decoded.match(/token=([^\s]+)/).captures.first
  end

  def csrf_token
    last_response.body.match(/name="_csrf" value="([^"]+)"/)&.captures&.first ||
      rack_mock_session.cookie_jar["lunula.session"] && begin
        get "/"
        last_response.body.match(/name="_csrf" value="([^"]+)"/).captures.first
      end
  end
end
