get "/posts", :index
get "/posts/:id", :show

guard Auth::Required do
  get "/posts/new", :new
  post "/posts", :create
  get "/posts/:id/edit", :edit
  patch "/posts/:id", :update
  delete "/posts/:id", :destroy
  post "/posts/:id/publish", :publish
  post "/posts/:id/archive", :archive
end
