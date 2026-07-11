# frozen_string_literal: true

module Products
  module Show
    def self.respond(context, params)
      {
        product: Repository.find(params[:id]),
        can_manage: !!context.current_user,
        subscriber: Subscriber.new,
        errors: []
      }
    end
  end
end
