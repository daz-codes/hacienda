# frozen_string_literal: true

module Franchises
  module Repository
    extend Lunula::Repository

    store database: APP.database, table: :venues, record: Venue

    def available
      all(dataset.where(published: true).order(:name))
    end
  end
end
