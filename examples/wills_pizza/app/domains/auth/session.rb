# frozen_string_literal: true

module Auth
  module Session
    module_function

    def login(context, user)
      context.reset_session!
      context.session[:user_id] = user.id
      context.current_user = user
    end

    def logout(context)
      context.reset_session!
      context.current_user = nil
    end

  end
end
