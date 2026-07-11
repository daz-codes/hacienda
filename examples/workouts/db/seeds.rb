# frozen_string_literal: true

def sample_plan(rounds)
  {
    "title" => "Neon Engine",
    "summary" => "A controlled run-and-erg session that builds repeatable power under fatigue.",
    "goal" => "Build sustainable mixed-modal power.",
    "warm_up" => {
      "duration_minutes" => 8,
      "instructions" => "Move continuously",
      "items" => ["4 min easy jog", "10 bodyweight squats", "10 walking lunges", "3 x 20 sec strides"]
    },
    "main_set" => {
      "format" => "Run and row intervals",
      "total_minutes" => 40,
      "sections" => [{
        "name" => "#{rounds}-round engine",
        "duration_minutes" => 40,
        "instructions" => "#{rounds} rounds · 60 sec recovery",
        "work" => ["600 m controlled run", "500 m row hard but repeatable"],
        "notes" => ["Keep every run split within five seconds."]
      }]
    },
    "cool_down" => {
      "duration_minutes" => 7,
      "instructions" => "Let the heart rate settle",
      "items" => ["5 min easy walk", "Calf and hip-flexor stretch"]
    },
    "coach_cue" => "Finish the first round knowing you could repeat it immediately.",
    "common_mistake" => "Turning the opening run into a time trial.",
    "why_it_works" => "Repeatable transitions teach you to preserve running form after hard erg work.",
    "scaling_summary" => "Beginner 3 rounds / Intermediate 4 rounds / Advanced 5 rounds"
  }
end

variants = {
  "beginner" => sample_plan(3),
  "intermediate" => sample_plan(4),
  "advanced" => sample_plan(5)
}

unless Workouts::Repository.dataset.where(activity: "Hyrox").any?
  Workouts::Repository.save(
    Workouts::Workout.new(
      activity: "Hyrox",
      training_notes: "No sled available. Focus on compromised running.",
      intensity: "high",
      duration: 55,
      generated_plan: variants.fetch("intermediate"),
      program_variants: variants
    )
  )
end
