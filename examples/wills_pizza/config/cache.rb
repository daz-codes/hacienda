# frozen_string_literal: true

cache_store = case ENV.fetch(
  "LUNULA_CACHE_STORE",
  Lunula.env.production? ? "null" : "memory"
)
when "memory"
  Lunula::Cache::MemoryStore.new(
    max_size: Integer(ENV.fetch("LUNULA_CACHE_SIZE", 1_000))
  )
when "null"
  Lunula::Cache::NullStore.new
else
  raise "unknown LUNULA_CACHE_STORE; configure a store in config/cache.rb"
end

Lunula.configure_cache(
  store: cache_store,
  namespace: File.basename(APP_ROOT)
)
