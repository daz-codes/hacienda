# Hacienda Workouts

A Hacienda version of the Volt workout generator. It demonstrates a substantial
single-domain application rather than a toy CRUD resource:

- plain Ruby domain objects with validation and composable behaviour;
- Sequel persistence with explicit JSON load/dump coercions in `Hacienda::Store`;
- OpenAI Responses API structured outputs isolated behind an injectable programmer;
- three pre-generated difficulty variants with instant scaling;
- HTML-first forms, CSRF, flash, security headers, and rate limiting;
- Helium live form state and partial page updates without Node.js or Turbo.
- Hacienda Navigation for prefetched, Idiomorph-powered GET transitions.

## Run it

```sh
cd examples/workouts
bundle install
bundle exec hac db:migrate
bundle exec hac db:seed
export OPENAI_API_KEY="your-api-key"
bundle exec hac start
```

Open <http://localhost:5151>. The seeded workout works without an API key; an
API key is only required to generate or regenerate a workout. You may store it
as `openai.api_key` in Hacienda encrypted credentials instead.

`OPENAI_MODEL` can override the example's `gpt-5.4-nano` default.

## Domain shape

`Workouts::Workout` includes `Programmable` and `Scalable`, so business verbs
read as `workout.generate`, `workout.scale_up`, and `workout.scale_down`.
HTTP actions remain small modules whose only job is translating requests and
responses around that domain behaviour.

The repository uses `STORE.dataset` for custom ordering and configures the two
JSON text columns explicitly:

```ruby
STORE = Hacienda::Store.new(
  database: APP.database,
  table: :workouts,
  record: Workout,
  coercions: {
    program_variants: {
      load: ->(value) { value.to_s.empty? ? {} : JSON.parse(value) },
      dump: ->(value) { JSON.generate(value || {}) }
    }
  }
)

def all
  STORE.all(STORE.dataset.reverse_order(:created_at))
end
```
