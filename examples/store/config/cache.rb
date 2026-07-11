# frozen_string_literal: true

cache_store = case ENV.fetch(
  "HACIENDA_CACHE_STORE",
  "memory"
)
when "memory"
  Hacienda::Cache::MemoryStore.new(
    max_size: Integer(ENV.fetch("HACIENDA_CACHE_SIZE", 1_000))
  )
when "null"
  Hacienda::Cache::NullStore.new
else
  raise "unknown HACIENDA_CACHE_STORE; configure a store in config/cache.rb"
end

Hacienda.configure_cache(
  store: cache_store,
  namespace: File.basename(APP_ROOT)
)
