get "/login", :login
post "/login", :authenticate
get "/magic-login", :magic_login, actions: :magic_login
post "/magic-login", :send_magic_link, actions: :magic_login
get "/magic-login/confirm", :confirm_magic_link, actions: :magic_login
post "/magic-login/confirm", :complete_magic_login, actions: :magic_login
get "/signup", :signup, actions: :registration
post "/signup", :create_account, actions: :registration
get "/verify-email", :verify_email, actions: :registration
post "/verify-email", :confirm_email, actions: :registration
post "/email-verification", :send_verification_email, actions: :registration

get "/password/forgot", :forgot_password, actions: :password
post "/password/forgot", :send_password_reset, actions: :password
get "/password/reset", :reset_password, actions: :password
patch "/password", :update_password, actions: :password

guard Auth::Required do
  delete "/logout", :logout
end
