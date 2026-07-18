get "/", :index
get "/products", :index
get "/products/:id", :show
post "/products/:id/subscribers", :subscribe, actions: :subscription
get "/unsubscribe", :unsubscribe, actions: :subscription
post "/unsubscribe", :confirm_unsubscribe, actions: :subscription

guard Auth::Required do
  get "/products/new", :new, actions: :management
  post "/products", :create, actions: :management
  get "/products/:id/edit", :edit, actions: :management
  patch "/products/:id", :update, actions: :management
  delete "/products/:id", :destroy, actions: :management
end
