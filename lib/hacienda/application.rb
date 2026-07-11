# frozen_string_literal: true

require "stringio"

module Hacienda
  class Application
    UNDEFINED = Object.new.freeze

    attr_reader :root, :routes, :renderer, :loader, :context_loaders, :database, :events, :outbox, :job_outbox, :navigation, :cache, :storage

    def initialize(
      root:,
      layout: "application",
      title: "Hacienda",
      reload: false,
      context_loaders: [],
      database: nil,
      events: nil,
      outbox: nil,
      job_outbox: nil,
      cache: nil,
      storage: nil,
      navigation: true
    )
      @root = File.expand_path(root)
      Hacienda.root = @root
      @routes = Routes.new
      @renderer = Renderer.new(root: @root, layout: layout, title:)
      @context_loaders = context_loaders
      @database = database
      @events = events || Events.new
      @outbox = outbox
      if @outbox && (!@database || @outbox.database != @database)
        raise ArgumentError, "event outbox must use the application's database"
      end
      @job_outbox = job_outbox
      if @job_outbox && (!@database || @job_outbox.database != @database)
        raise ArgumentError, "job outbox must use the application's database"
      end
      @cache = cache || Cache.new
      @storage = storage || Storage.new
      @navigation = Navigation.new(navigation)
      @reload_mutex = Mutex.new
      @inline_action_constants = {}
      @loader = Zeitwerk::Loader.new
      @domains_path = File.join(@root, "app", "domains")
      @loader.push_dir(@domains_path)
      @loader.collapse(File.join(@domains_path, "*", "actions"))
      @loader.ignore(File.join(@domains_path, "*", "actions.rb"))
      @loader.ignore(File.join(@domains_path, "*", "routes.rb"))
      @loader.on_load do |_constant_path, value, file|
        if action_file?(file) && value.is_a?(Module) && !value.singleton_class.ancestors.include?(Responses)
          value.extend(Responses)
        end
      end
      @loader.enable_reloading if reload
      @loader.setup
      load_inline_actions
      load_routes
    end

    def call(env)
      if loader.reloading_enabled?
        @reload_mutex.synchronize do
          reload_without_lock!
          dispatch(env)
        end
      else
        dispatch(env)
      end
    rescue NotFound => error
      not_found(env, error)
    rescue BadRequest => error
      bad_request(error)
    rescue StandardError => error
      handle_error(error, env)
    end

    def reload!
      @reload_mutex.synchronize { reload_without_lock! }
    end

    def transaction(**options)
      unless database
        raise Error, "database is not configured; pass database: DB to Hacienda::Application.new"
      end

      database.transaction(**options) do
        yield Transaction.new(
          database:,
          events:,
          outbox:,
          job_adapter: Hacienda.job_adapter,
          job_outbox:
        )
      end
    end

    private

    def dispatch(env)
      route, params = routes.find(env.fetch("REQUEST_METHOD"), env.fetch("PATH_INFO"))
      return not_found(env) unless route

      context = Context.new(env, application: self)
      params = Params.from_request(context.request, params)
      load_context(context)
      guarded_response = run_guards(route, context, params)
      return finish(guarded_response, route, context:) if guarded_response

      action = action_for(route)
      result = action.respond(context, params)
      finish(result, route, context:)
    end

    def reload_without_lock!
      unload_inline_actions
      loader.reload
      load_inline_actions
      routes.clear
      load_routes
      events.reload!
      self
    end

    def load_context(context)
      context_loaders.each do |loader_name|
        loader = loader_name.is_a?(String) ? constantize(loader_name) : loader_name
        loader.load(context)
      end
    end

    def run_guards(route, context, params)
      route.guards.each do |guard|
        guard.extend(Responses) unless guard.singleton_class.ancestors.include?(Responses)
        result = guard.check(context, params)
        return result unless result.nil?
      end

      nil
    end

    def action_for(route)
      unless inline_action_defined?(route)
        file = action_file(route)
        raise NotFound, "action not found: #{file}" unless File.file?(file)
      end

      route.action.tap do |action|
        action.extend(Responses) if action.is_a?(Module) && !action.singleton_class.ancestors.include?(Responses)
      end
    end

    def action_file(route)
      File.join(@domains_path, route.domain_name, "actions", "#{route.action_name}.rb")
    end

    def action_file?(file)
      file && file.start_with?(@domains_path) &&
        file.include?("#{File::SEPARATOR}actions#{File::SEPARATOR}")
    end

    def inline_actions_file(domain)
      File.join(@domains_path, domain, "actions.rb")
    end

    def load_inline_actions
      @inline_action_constants.clear
      Dir[File.join(@domains_path, "*", "actions.rb")].sort.each do |file|
        domain = File.basename(File.dirname(file))
        namespace = camelize(domain)
        inline_constants = inline_action_constant_names(file, namespace)
        clear_inline_action_autoloads(namespace, inline_constants)
        before = constants_for(namespace)
        load file
        after = constants_for(namespace)
        defined_inline_constants = inline_constants.select do |constant|
          Object.const_defined?(namespace, false) &&
            Object.const_get(namespace).const_defined?(constant, false)
        end
        @inline_action_constants[namespace] =
          defined_inline_constants.empty? ? after - before : defined_inline_constants
      end
    end

    def inline_action_constant_names(file, namespace)
      File.read(file).scan(/^\s*module\s+([A-Z]\w*)\b/).flatten
        .reject { |constant| constant == namespace }
        .map(&:to_sym)
    end

    def clear_inline_action_autoloads(namespace, constants)
      return unless Object.const_defined?(namespace, false)

      domain_module = Object.const_get(namespace)
      constants.each do |constant|
        domain_module.__send__(:remove_const, constant) if domain_module.const_defined?(constant, false)
      end
    end

    def unload_inline_actions
      @inline_action_constants.each do |namespace, constants|
        next unless Object.const_defined?(namespace, false)

        domain_module = Object.const_get(namespace)
        constants.each do |constant|
          domain_module.__send__(:remove_const, constant) if domain_module.const_defined?(constant, false)
        end
      end
      @inline_action_constants.clear
    end

    def constants_for(namespace)
      return [] unless Object.const_defined?(namespace, false)

      Object.const_get(namespace).constants(false)
    end

    def inline_action_defined?(route)
      namespace = camelize(route.domain_name)
      action = camelize(route.action_name).to_sym
      @inline_action_constants.fetch(namespace, []).include?(action) &&
        Object.const_defined?(namespace, false) &&
        Object.const_get(namespace).const_defined?(action, false)
    end

    def load_routes
      Dir[File.join(root, "app", "domains", "*", "routes.rb")].sort.each do |file|
        routes.draw(file, domain: File.basename(File.dirname(file)))
      end
    end

    def constantize(name)
      name.split("::").inject(Object) { |scope, constant| scope.const_get(constant) }
    end

    def camelize(value)
      value.to_s.split("_").map(&:capitalize).join
    end

    def finish(result, route, context: nil)
      case result
      when Hash
        finish_rendered(
          route,
          context,
          view: route.action_name,
          locals: result,
          status: 200
        )
      when View
        finish_rendered(
          route,
          context,
          view: result.name,
          locals: result.locals,
          status: result.status,
          layout: result.layout.nil? ? UNDEFINED : result.layout,
          navigable: result.layout != false
        )
      when Response
        finish_explicit_response(result, context)
      when Array
        result
      when nil
        finish_explicit_response(Response.new("", status: 204), context)
      else
        finish_explicit_response(Response.new(result.to_s), context)
      end
    end

    def finish_rendered(route, context, view:, locals:, status:, layout: UNDEFINED, navigable: true)
      locals = locals.merge(context:)
      morph = navigation.enabled? && context.navigation_request? &&
        !context.navigation_reload? && navigable

      rendered = if morph
        renderer.render_navigation(domain: route.domain_name, view:, locals:)
      else
        options = {domain: route.domain_name, view:, locals:}
        options[:layout] = layout unless layout.equal?(UNDEFINED)
        renderer.render_result(**options)
      end

      headers = context.response_headers.dup
      if navigation.enabled?
        headers["vary"] = "X-Hacienda-Navigation"
        headers["x-hacienda-title"] = header_value(rendered.title) if morph
        headers["x-hacienda-navigation"] = morph ? "morph" : "reload" if context.navigation_request?
        if context.prefetch?
          headers["x-hacienda-prefetch-cache"] = context.flash.any? ? "no-store" : "store"
        end
      end

      Response.new(rendered.body, status:, headers:).finish
    end

    def finish_explicit_response(result, context)
      headers = context.response_headers.merge(result.headers)
      headers["x-hacienda-navigation"] = "reload" if context.navigation_reload?
      Response.new(result.body, status: result.status, headers:).finish
    end

    def header_value(value)
      value.to_s.gsub(/[\r\n]/, " ")
    end

    def not_found(env = nil, error = nil)
      render_error_page(
        404,
        env:,
        title: "Not Found",
        message: "The page you were looking for could not be found.",
        error:
      ) || Response.new("Not Found", status: 404, headers: {"content-type" => "text/plain; charset=utf-8"}).finish
    end

    def bad_request(error)
      Response.new(
        error.message,
        status: 400,
        headers: {"content-type" => "text/plain; charset=utf-8"}
      ).finish
    end

    def handle_error(error, env = nil)
      report_sqlite_busy(error, env)
      Hacienda.logger.error("#{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}")
      if Hacienda.env.development?
        Response.new(Errors.render(error), status: 500).finish
      else
        render_error_page(
          500,
          env: env || error_env(error),
          title: "Application Error",
          message: "The application could not complete this request.",
          error:
        ) || Response.new(Errors.render(error), status: 500).finish
      end
    end

    def render_error_page(status, env: nil, **locals)
      return unless renderer.error_template?(status)

      context = Context.new(env || error_env, application: self)
      rendered = renderer.render_error(status:, locals: locals.merge(status:, context:))
      Response.new(
        rendered.body,
        status:,
        headers: {"content-type" => "text/html; charset=utf-8"}
      ).finish
    rescue StandardError => error
      Hacienda.logger.error("failed to render #{status} error page: #{error.class}: #{error.message}")
      nil
    end

    def error_env(error = nil)
      {
        "REQUEST_METHOD" => "GET",
        "SCRIPT_NAME" => "",
        "PATH_INFO" => "",
        "QUERY_STRING" => "",
        "rack.input" => StringIO.new,
        "rack.errors" => $stderr,
        "rack.session" => {},
        "rack.session.options" => {},
        "hacienda.error" => error
      }
    end

    def report_sqlite_busy(error, env)
      return unless env

      SQLite.report_busy(
        error,
        source: "request",
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"]
      )
    end
  end
end
