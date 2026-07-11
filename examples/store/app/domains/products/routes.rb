get "/", :index
get "/products", :index
get "/products/:id", :show
post "/products/:id/subscribers", :subscribe
get "/unsubscribe", :unsubscribe
post "/unsubscribe", :confirm_unsubscribe

guard Auth::Required do
  get "/products/new", :new
  post "/products", :create
  get "/products/:id/edit", :edit
  patch "/products/:id", :update
  delete "/products/:id", :destroy
end
