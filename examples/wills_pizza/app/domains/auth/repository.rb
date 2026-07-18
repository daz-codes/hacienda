# frozen_string_literal: true

module Auth
  module Repository
    STORE = Hacienda::Store.new(database: APP.database, table: :users, record: User)

    module_function

    def find(id)
      STORE.first(dataset.where(id: id))
    end

    def find_by_email(email)
      STORE.first(dataset.where(email: normalize(email)))
    end

    def save(user)
      user.email = normalize(user.email)
      STORE.save(user)
    end

    def dataset
      STORE.dataset
    end

    def normalize(email)
      email.to_s.strip.downcase
    end
  end
end
