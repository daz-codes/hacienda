# frozen_string_literal: true

service = if Hacienda.env.test?
  Hacienda::Storage::MemoryService.new
elsif Hacienda.env.production?
  Hacienda::Storage::NullService.new
else
  Hacienda::Storage::DiskService.new(root: File.join(APP_ROOT, "storage"))
end

Hacienda.configure_storage(service:)
