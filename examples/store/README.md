# Lunula Supply

This is the completed application from Lunula’s Rails Guides-style store
tutorial. It follows the current Rails 8.1 Getting Started store while using
Lunula’s domain-oriented structure and explicit Sequel persistence.

Read the complete tutorial in
[`docs/getting-started.md`](../../docs/getting-started.md).

## Run it

```sh
bundle install
bundle exec luna db:migrate
bundle exec luna db:seed
bundle exec luna start
```

Open <http://localhost:5151>. The seed creates:

- `admin@example.com`
- password: `change-this-password`

Development mail is written to `tmp/mail`. The seeded out-of-stock product has
`listener@example.com` subscribed, so changing its inventory above zero
demonstrates the after-commit event and queued notification email.

Useful commands:

```sh
bundle exec luna routes
bundle exec luna console
bundle exec rake test
bundle exec luna jobs:work
```

The application intentionally uses plain text descriptions because Lunula
does not yet provide rich-text editing, and it keeps English text inline because
i18n integration remains on the framework roadmap. Both gaps are identified in
the tutorial.
