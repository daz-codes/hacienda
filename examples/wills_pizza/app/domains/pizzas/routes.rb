get "/pizzas", :index
get "/pizzas/:id", :show

guard Auth::Required do
  get "/pizzas/new", :new, actions: :management
  post "/pizzas", :create, actions: :management
  get "/pizzas/:id/edit", :edit, actions: :management
  patch "/pizzas/:id", :update, actions: :management
end
