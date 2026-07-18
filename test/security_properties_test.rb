# frozen_string_literal: true

require_relative "test_helper"

class SecurityPropertiesTest < Minitest::Test
  include Hacienda::Responses

  ITERATIONS = 100

  def setup
    @random = Random.new(20_260_715)
    @previous_app_url = ENV["HACIENDA_APP_URL"]
    ENV["HACIENDA_APP_URL"] = "https://example.test"
  end

  def teardown
    ENV["HACIENDA_APP_URL"] = @previous_app_url
    ENV.delete("HACIENDA_APP_URL") unless @previous_app_url
  end

  def test_route_parameters_never_cross_path_segments
    route = Hacienda::Route.new(
      verb: "GET",
      path: "/posts/:id",
      action_name: :show,
      domain_name: :posts,
      order: 0
    )

    ITERATIONS.times do
      value = random_text
      assert_equal({"id" => value}, route.match("GET", "/posts/#{Rack::Utils.escape_path(value)}"))
      assert_nil route.match("GET", "/posts/#{value}/extra")
    end
  end

  def test_params_normalization_round_trips_random_nested_scalars
    ITERATIONS.times do
      source = {"item" => {"name" => random_text, "values" => [@random.rand(10_000), nil, true]}}
      params = Hacienda::Params.new(source)

      assert_equal source["item"]["name"], params.dig(:item, :name)
      assert_equal({item: {name: source["item"]["name"], values: source["item"]["values"]}}, params.to_h)
    end
  end

  def test_redirects_strip_header_breaks_and_reject_random_external_hosts
    ITERATIONS.times do
      relative = "/posts/#{random_text}\r\n"
      refute_match(/[\r\n]/, redirect(relative).headers.fetch("location"))

      host = "#{random_text.downcase}.invalid"
      assert_raises(Hacienda::UnsafeRedirect) { redirect("https://#{host}/path") }
    end
  end

  def test_signed_tokens_reject_random_single_byte_mutations
    signer = Hacienda::SignedToken.new(secret: "property-test-secret")

    ITERATIONS.times do |index|
      token = signer.generate({index:, value: random_text}, purpose: "property", expires_in: 60)
      offset = @random.rand(token.bytesize)
      replacement = token.getbyte(offset) == 65 ? "B" : "A"
      mutated = token.dup
      mutated[offset] = replacement

      assert_nil signer.verify(mutated, purpose: "property")
    end
  end

  def test_credentials_reject_random_ciphertext_mutations
    Dir.mktmpdir("hacienda-credential-properties") do |root|
      credentials = Hacienda::Credentials.new(root:).ensure_files
      credentials.write_text("api_key: value\n")
      original = File.binread(credentials.encrypted_path)

      ITERATIONS.times do
        mutated = original.dup
        offset = @random.rand(mutated.bytesize)
        mutated.setbyte(offset, mutated.getbyte(offset) ^ 1)
        File.binwrite(credentials.encrypted_path, mutated)

        assert_raises(Hacienda::Credentials::Error) { Hacienda::Credentials.new(root:).read_text }
      end
    end
  end

  def test_job_serializer_round_trips_random_json_values
    ITERATIONS.times do
      args = [@random.rand(10_000), random_text, [true, false, nil]]
      kwargs = {label: random_text, count: @random.rand(100)}

      loaded_args, loaded_kwargs = Hacienda::Jobs::Serializer.load(
        Hacienda::Jobs::Serializer.dump(args:, kwargs:)
      )

      assert_equal args, loaded_args
      assert_equal kwargs, loaded_kwargs
    end
  end

  def test_storage_keys_reject_random_traversal_segments
    ITERATIONS.times do
      key = "#{random_text}/../#{random_text}"
      assert_raises(Hacienda::Storage::InvalidKey) { Hacienda::Storage.validate_key!(key) }
    end
  end

  private

  def random_text
    Array.new(@random.rand(4..16)) { (97 + @random.rand(26)).chr }.join
  end
end
