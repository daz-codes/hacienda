# frozen_string_literal: true

storage_service = case ENV.fetch(
  "LUNULA_STORAGE_SERVICE",
  Lunula.env.test? ? "memory" : Lunula.env.production? ? "null" : "disk"
)
when "disk"
  Lunula::Storage::DiskService.new(
    root: ENV.fetch("LUNULA_STORAGE_ROOT", File.join(APP_ROOT, "storage"))
  )
when "memory"
  Lunula::Storage::MemoryService.new
when "null"
  Lunula::Storage::NullService.new
else
  raise "unknown LUNULA_STORAGE_SERVICE; configure a service in config/storage.rb"
end

Lunula.configure_storage(service: storage_service)
