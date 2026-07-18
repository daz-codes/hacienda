# frozen_string_literal: true

require_relative "../test_helper"

class FranchisesTest < ApplicationTest
  def setup
    database[:venues].delete if database.table_exists?(:venues)
  end

  def test_public_directory_lists_published_venues_only
    create_venue(
      name: "Will's Pizza Soho",
      slug: "soho",
      address: "12 Ruby Street, London",
      published: true
    )
    create_venue(
      name: "Will's Pizza Camden",
      slug: "camden",
      address: "24 Gem Road, London",
      published: true
    )
    create_venue(
      name: "Will's Pizza Brighton",
      slug: "brighton",
      address: "8 Seaside Avenue, Brighton",
      published: false
    )

    get "/franchises"

    assert_equal 200, last_response.status
    assert_includes last_response.body, "Will&#39;s Pizza Soho"
    assert_includes last_response.body, "12 Ruby Street, London"
    assert_includes last_response.body, "Will&#39;s Pizza Camden"
    assert_includes last_response.body, "24 Gem Road, London"
    refute_includes last_response.body, "Will&#39;s Pizza Brighton"
    refute_includes last_response.body, "8 Seaside Avenue, Brighton"
  end

  private

  def create_venue(name:, slug:, address:, published:)
    Franchises::Venue.new(name:, slug:, address:, published:).tap do |venue|
      Franchises::Repository.save(venue)
    end
  end
end
