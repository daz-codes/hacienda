# frozen_string_literal: true

module Auth
  module Repository
    extend Lunula::Repository

    store database: APP.database, table: :users, record: User

    def find_by_email(email)
      find_by(email: normalize(email))
    end

    def save(user)
      user.email = normalize(user.email)
      super
    end

    private

    def normalize(email)
      email.to_s.strip.downcase
    end
  end
end
