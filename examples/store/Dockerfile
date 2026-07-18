# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.3.6
FROM ruby:${RUBY_VERSION}-slim AS base

WORKDIR /app

ENV LUNULA_ENV="production" \
    RACK_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates libsqlite3-0 && \
    rm -rf /var/lib/apt/lists/*

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libsqlite3-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf /usr/local/bundle/cache /usr/local/bundle/ruby/*/cache

COPY . .
RUN bundle exec luna assets:precompile

FROM base

RUN groupadd --system lunula && \
    useradd --system --gid lunula --create-home lunula

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=lunula:lunula /app /app

RUN mkdir -p db log storage tmp && chown -R lunula:lunula db log storage tmp

USER lunula

EXPOSE 5151

CMD ["bundle", "exec", "rackup", "--host", "0.0.0.0", "--port", "5151"]
