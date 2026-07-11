# frozen_string_literal: true

module Auth
  module Required
    module_function

    def check(context, _params)
      redirect("/login") unless context.current_user
    end
  end
end
