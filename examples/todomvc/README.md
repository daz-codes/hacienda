# Hacienda TodoMVC

A server-backed TodoMVC-style example built with Hacienda and a lot of Helium.

The important point: this is still HTML-first. Every write is a normal form
submission protected by CSRF. Helium provides progressive enhancement for local
filtering, counters, edit affordances, keyboard shortcuts, optimistic UI updates,
draft previews, and small bits of interface state.

Hacienda Navigation handles GET page transitions independently. Helium remains
responsible for the TodoMVC interactions; unchanged directive-bearing nodes
keep their state across Idiomorph morphs.

## Run it

```sh
bundle install
bundle exec hac db:migrate
bundle exec hac db:seed
bundle exec hac start
```

Visit `http://localhost:5151`.

Open a console with the app loaded:

```sh
bundle exec hac console
```

## Interesting files

```text
app/domains/todos/
├── routes.rb
├── actions.rb
├── todo.rb
├── repository.rb
└── views/
    ├── index.erb
    └── todo.erb

public/assets/
├── application.css
├── hacienda-navigation.js
├── helium-csp.js
├── helium.js
├── idiomorph.esm.js
├── jexpr.js
└── todos.js
```

The view imports plain browser JavaScript directly:

```erb
@import="/assets/todos.js"
```

No bundler, no Node.js runtime, no SPA requirement.
