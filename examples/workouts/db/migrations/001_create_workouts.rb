# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:workouts) do
      primary_key :id
      String :activity, null: false
      String :training_notes, text: true
      String :intensity, null: false, default: "high"
      Integer :duration, null: false, default: 60
      String :scale_level, null: false, default: "intermediate"
      String :generated_plan, text: true
      String :program_variants, text: true, null: false, default: "{}"
      DateTime :created_at, null: false
      DateTime :updated_at, null: false

      check { duration >= 20 }
      check { duration <= 120 }
      check { intensity =~ %w[low moderate high maximum] }
      check { scale_level =~ %w[beginner intermediate advanced] }
    end
  end
end
