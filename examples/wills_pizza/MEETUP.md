# Will's Pizza Meetup Guide

## A Quick Hacienda Introduction

- Hacienda is a pre-1.0, domain-oriented Ruby web framework built on Rack,
  Sequel, ERB, and Zeitwerk.
- It aims at the same HTML-first, full-stack territory as modern Rails, without
  requiring Rails, Active Record, or a Node toolchain.
- Code is grouped by business domain rather than by framework-wide folders:
  each domain owns its routes, actions, model objects, repository, and views.
- Actions are ordinary instance methods receiving `(context, params)`. Hacienda
  creates a fresh action object for every request.
- Data flow stays explicit: an action returns a locals hash or an explicit
  render/redirect response; views only receive those locals and the request
  context.
- Persistence is explicit through small repositories and Sequel. Domain objects
  are plain Ruby objects using `Hacienda::Attributes` and validations where
  useful.
- HTML is rendered on the server. Hacienda navigation and Helium can add partial
  page updates and small interactions without making JavaScript the application
  architecture.
- Authentication, mail, jobs, events, caching, storage, security middleware,
  encrypted credentials, and deployment foundations are included.
- Be candid: it is pre-1.0 and intentionally much smaller than Rails. It does
  not yet have Rails' ecosystem, years of production evidence, or breadth.

## The Story

Will runs a pizza shop. Everyone can see the current menu and place an order.
Will can sign in to add or edit pizzas. An order must retain the name and price
the customer agreed to, even if the menu changes tomorrow.

That story suggests business boundaries before it suggests tables or
controllers.

## Domain Map

### `Pizzas`

Owns the menu and the meaning of a pizza. `Pizza` validates menu data,
`Repository` contains menu queries and persistence, public `Actions` browse the
menu, and `ManagementActions` contains the staff-only write workflow.

The route file makes access visible:

```ruby
get "/pizzas", :index
get "/pizzas/:id", :show

guard Auth::Required do
  get "/pizzas/new", :new, actions: :management
  post "/pizzas", :create, actions: :management
end
```

### `Orders`

Owns the checkout workflow rather than being a generic CRUD resource.
`Checkout` turns permitted customer input and the current menu into a valid
`Order`. `LineItem` snapshots the pizza name and unit price. `Repository#save`
persists the order and its items inside the transaction started by the action.

The public confirmation URL uses a random token, not an enumerable database ID,
because it displays customer details.

### `Auth`

Owns identity, credential checking, sessions, signed single-use tokens, email,
and `Auth::Required`. The pizza domain depends only on the guard at its route
boundary; ordering remains public.

### `Home`

Has one small responsibility: redirect `/` to the menu. A domain does not need
to contain a database-backed model.

## A 60-Minute Build

1. **Five minutes: scaffold and orient.** Generate the app, auth, and the two
   domains. Run `hac routes` and point out that each business area is together.
2. **Fifteen minutes: build the menu.** Add the pizza migration, `Pizza`, its
   repository queries, public action methods, routes, and the menu view.
3. **Ten minutes: protect menu management.** Generate auth, seed Will's verified
   user, wrap write routes in `guard Auth::Required`, and add `ManagementActions`.
4. **Twenty minutes: model checkout.** Add order tables, `Order`, `LineItem`, and
   `Checkout`; validate quantities and snapshot price/name before persistence.
5. **Five minutes: render the workflow.** Add the order form and random-token
   confirmation page.
6. **Five minutes: prove the boundaries.** Run the integration tests, change a
   pizza after ordering, and show that the receipt still has the original price.

Useful starting commands:

```sh
hac new wills_pizza
cd wills_pizza
bundle exec hac generate auth
bundle exec hac generate domain pizzas
bundle exec hac generate domain orders
bundle exec hac db:migrate
bundle exec hac routes
bundle exec rake test
```

For a shorter live session, provide the migrations and auth domain in advance.
Let attendees implement the `Pizzas` flow first, then pair on `Orders`.

## Thinking Differently From Rails

- Start with a business capability and its language, not with `rails generate
  scaffold Pizza`. Here, `Checkout` is a named workflow and `LineItem` is a
  price snapshot, not merely an association.
- Do not look for one global `app/models`, `app/controllers`, or `app/views`.
  Ask which domain owns a rule, then keep its HTTP edge, behavior, persistence,
  and presentation close together.
- An action is not a stateful Rails controller. Treat `(context, params)` as the
  input, use private helpers freely, and return explicit locals or a response.
- Do not pass request parameters straight into persistence. Use `permit`, then
  translate strings and check domain rules at the boundary.
- Repositories make database access visible. Add a query because the domain
  needs it (`available`, `find_by_token`), rather than growing an implicit model
  API across the application.
- Transactions belong around a complete business change. The action starts the
  request-level transaction; the repository performs the related writes.
- Cross-domain references should express a real dependency. `Orders` may read
  the available pizza menu at checkout, but it stores its own historical facts
  rather than depending on mutable pizza records forever.
- Prefer server-rendered HTML first. Add Helium behavior only when it improves a
  particular interaction; do not begin by designing a JSON API and SPA.
- Keep the framework small in your head: Rack request, route, fresh action,
  domain work, repository, returned locals, ERB response.

## Questions To Ask The Room

- Should the menu be `Pizzas`, `Menu`, or two domains? What future requirement
  would make you split it?
- What should happen if a pizza becomes unavailable while a customer has the
  order form open?
- Is a delivery address part of `Orders`, or does delivery become its own domain
  once drivers and delivery slots exist?
- Which actions require authentication, and which eventually require a more
  specific authorization policy than “signed in”?

## Stretch Work

- Add order status management for kitchen staff.
- Send an order confirmation using Hacienda mail and enqueue delivery after the
  database transaction commits.
- Add size and topping choices without turning `Pizza` into an unbounded bag of
  options.
- Add an availability conflict response when a stale order form is submitted.
- Use Helium to update the visible basket total while preserving normal form
  submission as the source of truth.
