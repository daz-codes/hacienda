# frozen_string_literal: true

module Hacienda
  class Routes
    class CollisionError < Hacienda::Error; end

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
      define_method(verb) do |path, action_name, guard: nil, actions: nil|
        raise ArgumentError, "routes must be declared inside a domain route file" unless @current_domain

        location = caller_locations(1, 1).first
        add Route.new(
          verb: verb,
          path: path,
          action_name: action_name,
          domain_name: @current_domain,
          action_group: actions,
          order: entries.length,
          guards: @guard_stack + Array(guard),
          source_file: location.absolute_path || location.path,
          source_line: location.lineno
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

    private

    def add(route)
      entries.each do |existing|
        reason = collision_reason(existing, route)
        raise CollisionError, collision_message(existing, route, reason) if reason
      end

      entries << route
      route
    end

    def collision_reason(existing, route)
      return unless existing.verb == route.verb
      return :duplicate if existing.path == route.path
      return :structural if existing.structural_path == route.structural_path

      overlap = existing.overlap_path(route)
      return unless overlap && existing.static_segment_count == route.static_segment_count

      [:ambiguous, overlap]
    end

    def collision_message(existing, route, reason)
      explanation = case reason
      when :duplicate
        "duplicate normalized verb and path"
      when :structural
        "structurally equivalent dynamic paths (#{existing.structural_path})"
      else
        "same-specificity patterns can both match #{reason.last}"
      end

      <<~MESSAGE.chomp
        Route collision for #{route.verb}: #{explanation}.
          #{route_description(existing)}
          #{route_description(route)}
        Use distinct paths or HTTP verbs so route ownership is unambiguous.
      MESSAGE
    end

    def route_description(route)
      "#{route.source_location} [#{route.domain_name}] #{route.path} -> #{route.action_handler_name}"
    end
  end
end
