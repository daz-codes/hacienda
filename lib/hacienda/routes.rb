# frozen_string_literal: true

module Hacienda
  class Routes
    VERBS = %i[get post put patch delete].freeze

    attr_reader :entries

    def initialize
      @entries = []
      @guard_stack = []
    end

    def clear
      entries.clear
      @guard_stack.clear
      self
    end

    def draw(file, domain:)
      @current_domain = domain
      @guard_stack.clear
      instance_eval(File.read(file), file, 1)
    ensure
      @current_domain = nil
      @guard_stack.clear
    end

    def guard(*guards)
      pushed = 0
      raise ArgumentError, "guard requires at least one guard" if guards.empty?
      raise ArgumentError, "guard requires a block" unless block_given?

      guards = guards.flatten
      @guard_stack.concat(guards)
      pushed = guards.length
      yield
    ensure
      pushed.to_i.times { @guard_stack.pop }
    end

    VERBS.each do |verb|
      define_method(verb) do |path, action_name, guard: nil|
        raise ArgumentError, "routes must be declared inside a domain route file" unless @current_domain

        entries << Route.new(
          verb: verb,
          path: path,
          action_name: action_name,
          domain_name: @current_domain,
          order: entries.length,
          guards: @guard_stack + Array(guard)
        )
      end
    end

    def find(method, path)
      entries
        .filter_map do |route|
          params = route.match(method, path)
          [route, params] if params
        end
        .max_by { |route, _params| route.specificity }
    end
  end
end
