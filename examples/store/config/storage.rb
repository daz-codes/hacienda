# frozen_string_literal: true

storage_service = case ENV.fetch(
  "HACIENDA_STORAGE_SERVICE",
  Hacienda.env.test? ? "memory" : "disk"
)
when "disk"
  Hacienda::Storage::DiskService.new(
    root: ENV.fetch("HACIENDA_STORAGE_ROOT", File.join(APP_ROOT, "storage"))
  )
when "memory"
  Hacienda::Storage::MemoryService.new
when "null"
  Hacienda::Storage::NullService.new
else
  raise "unknown HACIENDA_STORAGE_SERVICE; configure a service in config/storage.rb"
end

Hacienda.configure_storage(service: storage_service)
