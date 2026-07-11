get "/", :index
get "/active", :index
get "/completed", :index

post "/todos", :create
patch "/todos/toggle_all", :toggle_all
delete "/todos/completed", :clear_completed
patch "/todos/:id", :toggle
patch "/todos/:id/title", :update_title
delete "/todos/:id", :destroy
