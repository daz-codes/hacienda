get "/login", :login
post "/login", :authenticate
get "/magic-login", :magic_login
post "/magic-login", :send_magic_link
get "/magic-login/confirm", :confirm_magic_link
post "/magic-login/confirm", :complete_magic_login
get "/signup", :signup
post "/signup", :create_account
get "/verify-email", :verify_email
post "/verify-email", :confirm_email
post "/email-verification", :send_verification_email

get "/password/forgot", :forgot_password
post "/password/forgot", :send_password_reset
get "/password/reset", :reset_password
patch "/password", :update_password

guard Auth::Required do
  delete "/logout", :logout
end
