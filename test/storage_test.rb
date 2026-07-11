# frozen_string_literal: true

require_relative "test_helper"
require "rack/test"

class StorageTest < Minitest::Test
  def setup
    @temporary_files = []
  end

  def teardown
    @temporary_files.each(&:close!)
  end

  def test_upload_normalizes_rack_multipart_hashes_and_filenames
    file = temporary_file("hello")
    upload = Hacienda::Storage::Upload.wrap(
      tempfile: file,
      filename: "..\\notes.txt",
      type: "Text/Plain; charset=utf-8"
    )

    assert_equal "notes.txt", upload.filename
    assert_equal "text/plain", upload.content_type
    assert_equal 5, upload.byte_size
    assert_match(/\Asha256:[a-f0-9]{64}\z/, upload.checksum)
    assert_equal 0, upload.io.pos
  end

  def test_store_returns_metadata_and_uses_unpredictable_versioned_keys
    service = Hacienda::Storage::MemoryService.new
    storage = Hacienda::Storage.new(
      service:,
      clock: -> { Time.utc(2026, 6, 28) },
      key_generator: -> { "generated-id" }
    )

    blob = storage.store(
      upload_hash("hello", filename: "photo.PNG", type: "image/png"),
      prefix: "avatars",
      max_bytes: 10,
      content_types: ["image/*"]
    )

    assert_equal "avatars/2026/06/generated-id.png", blob.key
    assert_equal "photo.PNG", blob.filename
    assert_equal "image/png", blob.content_type
    assert_equal 5, blob.byte_size
    assert_match(/\Asha256:/, blob.checksum)
    assert_equal "/uploads/avatars/2026/06/generated-id.png", blob.url
    assert_equal "hello", storage.read(blob.key)
    assert storage.exist?(blob.key)
    assert storage.delete(blob.key)
    refute storage.exist?(blob.key)
  end

  def test_upload_size_and_content_type_validation
    storage = Hacienda::Storage.new(service: Hacienda::Storage::MemoryService.new)
    upload = upload_hash("too large", filename: "notes.txt", type: "text/plain")

    assert_raises(Hacienda::Storage::TooLarge) do
      storage.store(upload, max_bytes: 3)
    end
    assert_raises(Hacienda::Storage::UnsupportedType) do
      storage.store(upload, content_types: ["image/*"])
    end
  end

  def test_explicit_keys_reject_traversal_and_do_not_overwrite_by_default
    storage = Hacienda::Storage.new(service: Hacienda::Storage::MemoryService.new)
    upload = upload_hash("first")

    ["../secret", "/absolute", "nested//file", "nested\\file", "./file"].each do |key|
      assert_raises(Hacienda::Storage::InvalidKey) { storage.store(upload, key:) }
    end

    storage.store(upload, key: "documents/file.txt")
    assert_raises(Hacienda::Storage::AlreadyExists) do
      storage.store(upload_hash("second"), key: "documents/file.txt")
    end
    storage.store(upload_hash("second"), key: "documents/file.txt", overwrite: true)
    assert_equal "second", storage.read("documents/file.txt")
  end

  def test_memory_service_atomically_rejects_concurrent_writes_to_the_same_key
    storage = Hacienda::Storage.new(service: Hacienda::Storage::MemoryService.new)
    results = 12.times.map do |index|
      Thread.new do
        storage.store(
          {tempfile: StringIO.new("value-#{index}"), filename: "file.txt", type: "text/plain"},
          key: "documents/shared.txt"
        )
        :stored
      rescue Hacienda::Storage::AlreadyExists
        :exists
      end
    end.map(&:value)

    assert_equal 1, results.count(:stored)
    assert_equal 11, results.count(:exists)
    assert_match(/\Avalue-\d+\z/, storage.read("documents/shared.txt"))
  end

  def test_disk_service_atomically_rejects_concurrent_writes_to_the_same_key
    root = Dir.mktmpdir("hacienda-storage-race")
    storage = Hacienda::Storage.new(service: Hacienda::Storage::DiskService.new(root:))
    results = 8.times.map do |index|
      Thread.new do
        storage.store(
          {tempfile: StringIO.new("disk-#{index}"), filename: "file.txt", type: "text/plain"},
          key: "documents/shared.txt"
        )
        :stored
      rescue Hacienda::Storage::AlreadyExists
        :exists
      end
    end.map(&:value)

    assert_equal 1, results.count(:stored)
    assert_equal 7, results.count(:exists)
    assert_match(/\Adisk-\d+\z/, storage.read("documents/shared.txt"))
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_disk_service_writes_inside_its_root
    root = Dir.mktmpdir("hacienda-storage")
    storage = Hacienda::Storage.new(service: Hacienda::Storage::DiskService.new(root:))

    blob = storage.store(upload_hash("on disk"), key: "documents/file.txt")

    assert_equal "on disk", File.binread(File.join(root, blob.key))
    assert_equal "on disk", storage.read(blob.key)
  ensure
    FileUtils.rm_rf(root) if root
  end

  def test_null_service_fails_loudly_on_write
    storage = Hacienda::Storage.new(service: Hacienda::Storage::NullService.new)

    error = assert_raises(Hacienda::Storage::Unavailable) do
      storage.store(upload_hash("data"))
    end
    assert_equal "storage is not configured", error.message
  end

  def test_local_file_middleware_serves_safe_images_and_forces_other_types_to_download
    storage = Hacienda::Storage.new(service: Hacienda::Storage::MemoryService.new)
    image = storage.store(
      upload_hash("png", filename: "image.png", type: "image/png"),
      key: "images/image.png"
    )
    html = storage.store(
      upload_hash("<script>x</script>", filename: "page.html", type: "text/html"),
      key: "documents/page.html"
    )
    app = Hacienda::Middleware::StorageFiles.new(
      ->(_env) { [418, {}, ["fallback"]] },
      storage:
    )
    request = Rack::MockRequest.new(app)

    image_response = request.get(image.url)
    assert_equal 200, image_response.status
    assert_equal "image/png", image_response["content-type"]
    assert_nil image_response["content-disposition"]
    assert_equal "png", image_response.body

    html_response = request.get(html.url)
    assert_equal 200, html_response.status
    assert_equal "text/html", html_response["content-type"]
    assert_match(/attachment/, html_response["content-disposition"])
    assert_equal "default-src 'none'; sandbox", html_response["content-security-policy"]

    head_response = request.request("HEAD", image.url)
    assert_equal 200, head_response.status
    assert_equal "", head_response.body
    assert_equal "3", head_response["content-length"]
  end

  def test_local_file_middleware_rejects_traversal_and_ignores_other_requests
    storage = Hacienda::Storage.new(service: Hacienda::Storage::MemoryService.new)
    app = Hacienda::Middleware::StorageFiles.new(
      ->(_env) { [418, {}, ["fallback"]] },
      storage:
    )
    request = Rack::MockRequest.new(app)

    assert_equal 404, request.get("/uploads/%2E%2E/secret").status
    assert_equal 404, request.get("/uploads/missing.txt").status
    assert_equal 418, request.post("/uploads/missing.txt").status
    assert_equal 418, request.get("/other").status
  end

  def test_real_multipart_request_can_be_stored_without_controller_plumbing
    storage = Hacienda::Storage.new(service: Hacienda::Storage::MemoryService.new)
    app = lambda do |env|
      upload = Rack::Request.new(env).params.fetch("file")
      blob = storage.store(upload, content_types: ["text/plain"])
      [201, {"content-type" => "text/plain"}, [blob.key]]
    end
    source = temporary_file("multipart body")
    uploaded = Rack::Test::UploadedFile.new(
      source.path,
      "text/plain",
      original_filename: "notes.txt"
    )

    session = Rack::Test::Session.new(Rack::MockSession.new(app))
    session.post("/", {"file" => uploaded})
    response = session.last_response

    assert_equal 201, response.status
    assert_equal "multipart body", storage.read(response.body)
  end

  private

  def upload_hash(content, filename: "file.txt", type: "text/plain")
    {tempfile: temporary_file(content), filename:, type:}
  end

  def temporary_file(content)
    Tempfile.new("hacienda-upload").tap do |file|
      file.binmode
      file.write(content)
      file.rewind
      @temporary_files << file
    end
  end
end
