# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "rack"
require "rack/test"
require "sequel"
require "sequel/extensions/migration"
require "tmpdir"
require "fileutils"

WORKOUTS_ROOT = File.expand_path("../..", __dir__)
test_database_directory = unless ENV["DATABASE_URL"]
  Dir.mktmpdir("lunula-workouts-test").tap do |directory|
    ENV["DATABASE_URL"] = "sqlite://#{File.join(directory, "test.sqlite3")}"
  end
end
WORKOUTS_APP = Rack::Builder.parse_file(File.join(WORKOUTS_ROOT, "config.ru"))

Minitest.after_run do
  DB.disconnect
  FileUtils.rm_rf(test_database_directory) if test_database_directory
end

Sequel::Migrator.run(DB, File.join(WORKOUTS_ROOT, "db", "migrations"))
Workouts::Workout.name

class WorkoutsTest < Minitest::Test
  include Rack::Test::Methods

  def app
    WORKOUTS_APP
  end

  def setup
    DB[:workouts].delete
    clear_cookies
    Workouts.programmer = ->(_workout) { program_variants }
  end

  def teardown
    Workouts.reset_programmer!
  end

  def test_generates_and_persists_a_structured_workout
    get "/workouts/new"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Lunula + OpenAI"

    post "/workouts", {
      _csrf: csrf_token,
      workout: {
        activity: "Hyrox",
        training_notes: "No sled available",
        intensity: "high",
        duration: "60"
      }
    }

    assert_equal 303, last_response.status
    workout = Workouts::Repository.all.first
    assert_equal "Intermediate Neon Engine", workout.generated_plan["title"]
    assert_equal %w[advanced beginner intermediate], workout.program_variants.keys.sort
    assert_equal "No sled available", workout.training_notes

    follow_redirect!
    assert_includes last_response.body, "Intermediate Neon Engine"
  end

  def test_rejects_invalid_input_without_calling_the_programmer
    Workouts.programmer = ->(_workout) { flunk "programmer should not be called" }
    get "/workouts/new"

    post "/workouts", {
      _csrf: csrf_token,
      workout: {activity: "", training_notes: "", intensity: "extreme", duration: "5"}
    }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "Activity is required"
    assert_equal 0, DB[:workouts].count
  end

  def test_scales_with_html_fallback_and_a_helium_fragment
    workout = persist_workout
    get "/workouts/#{workout.id}"

    patch "/workouts/#{workout.id}/scale-up", {_csrf: csrf_token}
    assert_equal 303, last_response.status
    assert_equal "advanced", Workouts::Repository.find(workout.id).scale_level

    follow_redirect!
    patch "/workouts/#{workout.id}/scale-down",
      {_csrf: csrf_token},
      {"HTTP_ACCEPT" => "text/event-stream,text/vnd.turbo-stream.html,application/json,text/html"}

    assert_equal 200, last_response.status
    assert_includes last_response.body, %(<section id="program")
    refute_includes last_response.body, "<!doctype html>"
    assert_includes last_response.body, "Intermediate Neon Engine"
  end

  def test_helium_enhances_the_form_and_scaling_controls_under_csp
    workout = persist_workout

    get "/workouts/new"
    assert_includes last_response.body, %(@bind="duration")
    assert_includes last_response.body, %(@calculate:durationLabel="formatDuration(duration)")
    assert_includes last_response.body, %(<script src="/assets/helium-csp.js" type="module"></script>)
    assert_equal "default-src 'self'", last_response["content-security-policy"].split(";").first

    get "/workouts/#{workout.id}"
    assert_includes last_response.body, %(@patch="/workouts/#{workout.id}/scale-up")
    assert_includes last_response.body, %(@target="#program:replace")

    get "/assets/workouts.js"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "formatDuration"
  end

  def test_csrf_protection_rejects_unsafe_requests
    post "/workouts", {workout: {activity: "Running"}}

    assert_equal 403, last_response.status
  end

  private

  def persist_workout
    variants = program_variants
    Workouts::Repository.save(
      Workouts::Workout.new(
        activity: "Hyrox",
        training_notes: "No sled available",
        intensity: "high",
        duration: 60,
        generated_plan: variants.fetch("intermediate"),
        program_variants: variants
      )
    )
  end

  def program_variants
    {
      "beginner" => plan("Beginner Neon Engine", 3),
      "intermediate" => plan("Intermediate Neon Engine", 4),
      "advanced" => plan("Advanced Neon Engine", 5)
    }
  end

  def plan(title, rounds)
    {
      "title" => title,
      "summary" => "A controlled mixed-modal session.",
      "goal" => "Build repeatable power.",
      "warm_up" => {
        "duration_minutes" => 8,
        "instructions" => "Move continuously",
        "items" => ["4 min jog", "10 squats"]
      },
      "main_set" => {
        "format" => "Run and row intervals",
        "total_minutes" => 40,
        "sections" => [{
          "name" => "#{rounds}-round engine",
          "duration_minutes" => 40,
          "instructions" => "#{rounds} rounds",
          "work" => ["600 m run", "500 m row"],
          "notes" => ["Hold even splits"]
        }]
      },
      "cool_down" => {
        "duration_minutes" => 7,
        "instructions" => "Easy movement",
        "items" => ["5 min walk"]
      },
      "coach_cue" => "Start under control.",
      "common_mistake" => "Starting too fast.",
      "why_it_works" => "It develops repeatable output.",
      "scaling_summary" => "Beginner 3 / Intermediate 4 / Advanced 5 rounds"
    }
  end

  def csrf_token
    last_response.body.match(/name="_csrf" value="([^"]+)"/)&.captures&.first || begin
      get "/workouts/new"
      last_response.body.match(/name="_csrf" value="([^"]+)"/).captures.first
    end
  end
end
