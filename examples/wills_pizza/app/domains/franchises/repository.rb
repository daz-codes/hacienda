# frozen_string_literal: true

module Franchises
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :venues, record: Venue)

    module_function

    def available
      STORE.all(STORE.dataset.where(published: true).order(:name))
    end

    def save(venue)
      STORE.save(venue)
    end

    def dataset
      STORE.dataset
    end
  end
end
