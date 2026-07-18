# Lunula website

The framework website is itself a small Lunula application. It has no
database or session state: routes map directly to action methods and ERB views.

Start it from this repository:

```sh
bundle install
bundle exec luna start
```

Open <http://localhost:5151>. The site includes:

- a product homepage explaining Lunula’s design;
- a ten-minute generated blog walkthrough;
- the complete Lunula Supply guide rendered from `docs/getting-started.md`.

Run its integration tests with:

```sh
bundle exec rake test
```
