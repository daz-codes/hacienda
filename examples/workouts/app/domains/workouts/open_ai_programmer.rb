# frozen_string_literal: true

require "json"
require "openai"

module Workouts
  module OpenAIProgrammer
    MODEL = ENV.fetch("OPENAI_MODEL", "gpt-5.4-nano")

    module_function

    def generate(workout)
      response = client.responses.create(
        model: MODEL,
        instructions: instructions,
        input: request_for(workout),
        text: {
          format: {
            type: "json_schema",
            name: "workout_programs",
            strict: true,
            schema: schema
          }
        },
        max_output_tokens: 12_000
      )

      content = response.output.flat_map(&:content).find do |item|
        item.respond_to?(:text) && !item.text.to_s.empty?
      end
      raise Programmable::GenerationError, "The model did not return a workout plan. Please try again." unless content

      JSON.parse(content.text)
    rescue OpenAI::Errors::Error => error
      Hacienda.logger.error("OpenAI workout generation failed: #{error.class}: #{error.message}")
      raise Programmable::GenerationError, "We could not generate the workout right now. Please try again."
    rescue JSON::ParserError
      raise Programmable::GenerationError, "The model returned an invalid workout. Please try again."
    end

    def client
      OpenAI::Client.new(api_key: api_key)
    end

    def api_key
      key = ENV["OPENAI_API_KEY"]
      if key.to_s.empty? && File.file?(File.join(Hacienda.root, "config", "credentials.yml.enc"))
        key = Hacienda.credentials.dig(:openai, :api_key)
      end
      return key unless key.to_s.empty?

      raise Programmable::GenerationError,
        "OpenAI is not configured. Set OPENAI_API_KEY or add openai.api_key to credentials."
    end

    def request_for(workout)
      <<~PROMPT
        Activity: #{workout.activity}
        Intensity: #{workout.intensity}
        Total duration: #{workout.duration} minutes
        Mandatory constraints: #{workout.training_notes.to_s.strip.empty? ? "None supplied" : workout.training_notes}

        Build beginner, intermediate, and advanced versions of the same coherent workout.
        Keep each version inside the total duration, including warm-up and cool-down.
      PROMPT
    end

    def instructions
      <<~PROMPT
        You are an experienced strength and conditioning coach.
        Write concise, practical sessions like a coach's whiteboard, not an article.
        Respect every equipment, injury, movement, and training constraint supplied by the user.
        Keep the same training intent across all three levels while scaling volume, load,
        complexity, work-to-rest ratio, or distance conservatively.
        Give the workout an original two-to-six-word title and include concrete work and rest.
        The sum of each main set's section durations must equal main_set.total_minutes.
      PROMPT
    end

    def schema
      {
        type: "object",
        additionalProperties: false,
        properties: Scalable::LEVELS.to_h { |level| [level, plan_schema] },
        required: Scalable::LEVELS
      }
    end

    def plan_schema
      {
        type: "object",
        additionalProperties: false,
        properties: {
          title: {type: "string"},
          summary: {type: "string"},
          goal: {type: "string"},
          warm_up: supporting_block_schema,
          main_set: main_set_schema,
          cool_down: supporting_block_schema,
          coach_cue: {type: "string"},
          common_mistake: {type: "string"},
          why_it_works: {type: "string"},
          scaling_summary: {type: "string"}
        },
        required: %w[
          title summary goal warm_up main_set cool_down coach_cue common_mistake
          why_it_works scaling_summary
        ]
      }
    end

    def supporting_block_schema
      {
        type: "object",
        additionalProperties: false,
        properties: {
          duration_minutes: {type: "integer"},
          instructions: {type: "string"},
          items: {type: "array", items: {type: "string"}}
        },
        required: %w[duration_minutes instructions items]
      }
    end

    def main_set_schema
      {
        type: "object",
        additionalProperties: false,
        properties: {
          format: {type: "string"},
          total_minutes: {type: "integer"},
          sections: {type: "array", items: section_schema}
        },
        required: %w[format total_minutes sections]
      }
    end

    def section_schema
      {
        type: "object",
        additionalProperties: false,
        properties: {
          name: {type: "string"},
          duration_minutes: {type: "integer"},
          instructions: {type: "string"},
          work: {type: "array", items: {type: "string"}},
          notes: {type: "array", items: {type: "string"}}
        },
        required: %w[name duration_minutes instructions work notes]
      }
    end
  end
end
