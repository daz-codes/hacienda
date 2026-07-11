# frozen_string_literal: true

require_relative "test_helper"
require "hacienda/generator"

class GeneratorSnapshotTest < Minitest::Test
  NEW_APP_FILES = %w[
    Gemfile
    Procfile.dev
    Rakefile
    config.ru
    config/application.rb
    config/jobs.rb
    config/litestream.yml.example
    config/cache.rb
    config/storage.rb
    config/environment.rb
    config/environments/development.rb
    config/environments/test.rb
    config/environments/production.rb
    db/migrations/20260629000000_create_hacienda_runtime.rb
    app/domains/home/routes.rb
    app/domains/home/actions/index.rb
    app/domains/home/actions/up.rb
    app/domains/home/views/index.erb
    app/errors/404.erb
    app/errors/500.erb
    app/layouts/application.erb
    test/test_helper.rb
    test/integration/home_test.rb
    README.md
  ].freeze

  REST_FILES = %w[
    app/domains/posts/routes.rb
    app/domains/posts/post.rb
    app/domains/posts/repository.rb
    app/domains/posts/actions.rb
    app/domains/posts/views/index.erb
    app/domains/posts/views/show.erb
    app/domains/posts/views/form.erb
  ].freeze

  AUTH_FILES = %w[
    Gemfile
    config.ru
    config/application.rb
    app/domains/auth/routes.rb
    app/domains/auth/user.rb
    app/domains/auth/repository.rb
    app/domains/auth/session.rb
    app/domains/auth/required.rb
    app/domains/auth/mailer.rb
    app/domains/auth/actions/authenticate.rb
    app/domains/auth/actions/complete_magic_login.rb
    app/domains/auth/actions/confirm_magic_link.rb
    app/domains/auth/actions/create_account.rb
    app/domains/auth/actions/confirm_email.rb
    app/domains/auth/actions/magic_login.rb
    app/domains/auth/actions/send_magic_link.rb
    app/domains/auth/actions/update_password.rb
    app/domains/auth/views/login.erb
    app/domains/auth/views/magic_login.erb
    app/domains/auth/views/magic_login_confirm.erb
    app/domains/auth/views/signup.erb
    app/domains/auth/views/reset_password.erb
  ].freeze

  def setup
    @directory = Dir.mktmpdir("hacienda-snapshot")
    @root = File.join(@directory, "snapshot")
    @framework_root = File.expand_path("..", __dir__)
    @generator = Hacienda::Generator.new(
      target: @root,
      source_root: @framework_root,
      cwd: @directory
    )
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def test_new_application_snapshot
    @generator.new_app

    assert_snapshot("new_app", entries(NEW_APP_FILES))
  end

  def test_rest_resource_snapshot
    @generator.new_app
    @generator.generate_rest("posts")
    migration = Dir[File.join(@root, "db", "migrations", "*_create_posts.rb")].fetch(0)

    assert_snapshot(
      "rest_resource",
      entries(REST_FILES) + [["db/migrations/TIMESTAMP_create_posts.rb", migration]]
    )
  end

  def test_auth_snapshot
    @generator.new_app
    @generator.generate_auth
    migration = Dir[File.join(@root, "db", "migrations", "*_create_users.rb")].fetch(0)

    assert_snapshot(
      "auth",
      entries(AUTH_FILES) + [["db/migrations/TIMESTAMP_create_users.rb", migration]]
    )
  end

  private

  def entries(paths)
    paths.map { |path| [path, File.join(@root, path)] }
  end

  def assert_snapshot(name, snapshot_entries)
    actual = snapshot_entries.sort_by(&:first).map do |label, path|
      content = File.read(path).gsub(@framework_root, "<FRAMEWORK_ROOT>")
      "===== #{label} =====\n#{content}"
    end.join("\n")
    snapshot = File.join(__dir__, "snapshots", "#{name}.snap")

    if ENV["UPDATE_SNAPSHOTS"] == "1"
      FileUtils.mkdir_p(File.dirname(snapshot))
      File.write(snapshot, actual)
    end

    assert File.file?(snapshot), "missing snapshot: #{snapshot}"
    assert_equal File.read(snapshot), actual
  end
end
