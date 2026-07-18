get "/posts", :index
get "/posts/:id", :show

guard Auth::Required do
  get "/posts/new", :new, actions: :management
  post "/posts", :create, actions: :management
  get "/posts/:id/edit", :edit, actions: :management
  patch "/posts/:id", :update, actions: :management
  delete "/posts/:id", :destroy, actions: :management
  post "/posts/:id/publish", :publish, actions: :publishing
  post "/posts/:id/archive", :archive, actions: :publishing
end
