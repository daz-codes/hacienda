# frozen_string_literal: true

service = if Lunula.env.test?
  Lunula::Storage::MemoryService.new
elsif Lunula.env.production?
  Lunula::Storage::NullService.new
else
  Lunula::Storage::DiskService.new(root: File.join(APP_ROOT, "storage"))
end

Lunula.configure_storage(service:)
