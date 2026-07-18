get "/", :index
get "/active", :index
get "/completed", :index

post "/todos", :create
patch "/todos/toggle_all", :toggle_all, actions: :completion
delete "/todos/completed", :clear_completed, actions: :completion
patch "/todos/:id", :toggle, actions: :completion
patch "/todos/:id/title", :update_title
delete "/todos/:id", :destroy
