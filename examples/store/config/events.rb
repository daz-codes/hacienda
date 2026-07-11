# frozen_string_literal: true

APP.events.configure do |events|
  events.subscribe Products::Events::Restocked, Products::NotifySubscribers
end
