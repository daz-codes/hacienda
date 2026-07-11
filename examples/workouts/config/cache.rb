# frozen_string_literal: true

store = if Hacienda.env.production?
  Hacienda::Cache::NullStore.new
else
  Hacienda::Cache::MemoryStore.new(max_size: 1_000)
end

Hacienda.configure_cache(store:, namespace: "workouts")
