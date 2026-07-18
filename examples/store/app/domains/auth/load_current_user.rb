# frozen_string_literal: true

module Auth
  module LoadCurrentUser
    module_function

    def load(context)
      user_id = context.session[:user_id]
      context.current_user = Repository.find_by(id: user_id) if user_id
    end
  end
end
