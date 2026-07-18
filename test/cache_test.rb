# frozen_string_literal: true

require_relative "test_helper"

class CacheTest < Minitest::Test
  class RecordingStore
    attr_reader :writes

    def initialize
      @values = {}
      @writes = []
    end

    def read(key)
      @values[key]
    end

    def write(key, value, expires_in: nil)
      @writes << [key, value, expires_in]
      @values[key] = value
    end

    def delete(key)
      !@values.delete(key).nil?
    end
  end

  def test_read_write_fetch_and_delete
    cache = Lunula::Cache.new
    calls = 0

    assert_equal "value", cache.write("key", "value")
    assert_equal "value", cache.read("key")
    assert_equal "value", cache.fetch("key") { calls += 1 }
    assert_equal 0, calls
    assert cache.delete("key")
    assert_nil cache.read("key")

    assert_equal "computed", cache.fetch("key") { calls += 1; "computed" }
    assert_equal 1, calls
  end

  def test_false_is_cached_but_nil_is_not
    cache = Lunula::Cache.new
    calls = 0

    2.times { cache.fetch("false") { calls += 1; false } }
    2.times { cache.fetch("nil") { calls += 1; nil } }

    assert_equal 3, calls
    assert_equal false, cache.read("false")
    assert_nil cache.read("nil")
  end

  def test_memory_store_expires_entries
    now = 10.0
    store = Lunula::Cache::MemoryStore.new(clock: -> { now })
    cache = Lunula::Cache.new(store:)

    cache.write("key", "value", expires_in: 5)
    now = 14.9
    assert_equal "value", cache.read("key")
    now = 15.0
    assert_nil cache.read("key")
    assert_equal 0, store.size
  end

  def test_expiry_must_be_positive_for_every_store
    cache = Lunula::Cache.new(store: Lunula::Cache::NullStore.new)

    assert_raises(ArgumentError) { cache.write("key", "value", expires_in: 0) }
    assert_raises(ArgumentError) { cache.fetch("key", expires_in: -1) { "value" } }
  end

  def test_memory_store_evicts_the_least_recently_used_entry
    store = Lunula::Cache::MemoryStore.new(max_size: 2)
    cache = Lunula::Cache.new(store:)
    cache.write("one", 1)
    cache.write("two", 2)
    cache.read("one")

    cache.write("three", 3)

    assert_equal 1, cache.read("one")
    assert_nil cache.read("two")
    assert_equal 3, cache.read("three")
  end

  def test_memory_store_is_thread_safe_and_bounded
    store = Lunula::Cache::MemoryStore.new(max_size: 25)
    cache = Lunula::Cache.new(store:)

    threads = 8.times.map do |thread|
      Thread.new do
        100.times do |index|
          key = [thread, index]
          cache.write(key, index)
          cache.read(key)
        end
      end
    end
    threads.each(&:join)

    assert_operator store.size, :<=, 25
  end

  def test_namespaces_and_pluggable_stores
    store = RecordingStore.new
    cache = Lunula::Cache.new(store:, namespace: "blog")

    cache.write(["posts", 1], "post", expires_in: 30)

    assert_equal [["blog/posts/1", "post", 30]], store.writes
    assert_equal "post", cache.read(["posts", 1])
  end

  def test_null_store_never_retains_values
    cache = Lunula::Cache.new(store: Lunula::Cache::NullStore.new)

    assert_equal "value", cache.write("key", "value")
    assert_nil cache.read("key")
    refute cache.delete("key")
  end

  def test_http_headers_and_freshness
    modified = Time.utc(2026, 6, 28, 12, 0, 0)
    headers = Lunula::Cache::HTTP.headers(
      etag: ["posts", 1, modified.to_i],
      last_modified: modified,
      public: true,
      max_age: 60
    )

    assert_match(/\A"[a-f0-9]{64}"\z/, headers["etag"])
    assert_equal "Sun, 28 Jun 2026 12:00:00 GMT", headers["last-modified"]
    assert_equal "public, max-age=60", headers["cache-control"]

    etag_request = Rack::Request.new(Rack::MockRequest.env_for(
      "/posts/1",
      "HTTP_IF_NONE_MATCH" => headers["etag"]
    ))
    date_request = Rack::Request.new(Rack::MockRequest.env_for(
      "/posts/1",
      "HTTP_IF_MODIFIED_SINCE" => headers["last-modified"]
    ))

    assert Lunula::Cache::HTTP.fresh?(etag_request, etag: headers["etag"])
    assert Lunula::Cache::HTTP.fresh?(date_request, last_modified: modified)
  end

  def test_http_freshness_ignores_conditional_headers_on_writes
    request = Rack::Request.new(Rack::MockRequest.env_for(
      "/posts/1",
      method: "POST",
      "HTTP_IF_NONE_MATCH" => "*"
    ))

    refute Lunula::Cache::HTTP.fresh?(request, etag: %("etag"))
  end
end
