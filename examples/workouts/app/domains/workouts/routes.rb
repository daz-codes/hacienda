get "/", :index
get "/workouts", :index
get "/workouts/new", :new
post "/workouts", :create
get "/workouts/:id", :show
get "/workouts/:id/edit", :edit
patch "/workouts/:id", :update
delete "/workouts/:id", :destroy
patch "/workouts/:id/scale-up", :scale_up, actions: :scaling
patch "/workouts/:id/scale-down", :scale_down, actions: :scaling
