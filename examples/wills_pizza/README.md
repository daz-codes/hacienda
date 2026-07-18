# Will's Pizza

A small Hacienda application for a Ruby meetup workshop. Customers can browse
the public menu and place an order. A signed-in member of staff can add and edit
pizzas.

## Run It

From this directory:

```sh
bundle install
bundle exec hac db:migrate
bundle exec hac db:seed
bundle exec hac start
```

Open <http://localhost:5151>. The seed account is:

```text
Email:    will@example.com
Password: wood-fired-pizza
```

Run the complete Rack integration suite with:

```sh
bundle exec rake test
```

## Application Shape

- `Pizzas` owns the menu, availability, price, and staff management actions.
- `Orders` owns checkout, quantity rules, customer details, and immutable line
  item price snapshots.
- `Franchises` owns the public venue directory and publication state.
- `Auth` owns users, password and magic-link authentication, sessions, and the
  guard used by staff-only routes.
- `Home` only decides where the root URL should lead.

Routes, action methods, domain objects, repositories, and views live together
under `app/domains/<domain>`. See [MEETUP.md](MEETUP.md) for the workshop plan
and the architectural discussion.
