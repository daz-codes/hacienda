# frozen_string_literal: true

store = if Lunula.env.production?
  Lunula::Cache::NullStore.new
else
  Lunula::Cache::MemoryStore.new(max_size: 1_000)
end

Lunula.configure_cache(store:, namespace: "todomvc")
