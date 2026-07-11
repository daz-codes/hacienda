# frozen_string_literal: true

APP.events.configure do |events|
  events.subscribe Posts::Events::Published, Posts::Activity.method(:record_published)
  events.subscribe Posts::Events::Archived, Posts::Activity.method(:record_archived)
end
