# frozen_string_literal: true

module Hacienda
  class Renderer
    Rendered = Data.define(:body, :title)
    UNDEFINED = Object.new.freeze

    def initialize(root:, layout: "application", title: "Hacienda")
      @root = root
      @layout = layout
      @title = title
    end

    def render(domain:, view:, locals:, layout: @layout)
      render_result(domain:, view:, locals:, layout:).body
    end

    def render_result(domain:, view:, locals:, layout: @layout)
      context = ViewContext.new(self, domain, locals, title: @title)
      content = evaluate(view_path(domain, view), context, locals)
      body = if layout
        evaluate(layout_path(layout), context, locals.merge(content: content))
      else
        content
      end

      Rendered.new(body:, title: context.page_title)
    end

    def render_navigation(domain:, view:, locals:)
      context = ViewContext.new(self, domain, locals, title: @title)
      content = evaluate(view_path(domain, view), context, locals)
      body = context.navigation_page(content, context: locals.fetch(:context))

      Rendered.new(body:, title: context.page_title)
    end

    def render_error(status:, locals:, layout: @layout)
      context = ViewContext.new(self, nil, locals, title: @title)
      content = evaluate(error_path(status), context, locals)
      body = if layout
        evaluate(layout_path(layout), context, locals.merge(content: content))
      else
        content
      end

      Rendered.new(body:, title: context.page_title)
    end

    def error_template?(status)
      File.file?(error_path(status))
    end

    def component(domain, name, locals)
      path = File.join(@root, "app", "domains", domain, "views", "components", "_#{name}.erb")
      evaluate(path, ViewContext.new(self, domain, locals, title: @title), locals)
    end

    def partial(domain, name, locals)
      path = File.join(@root, "app", "domains", domain, "views", "#{name}.erb")
      evaluate(path, ViewContext.new(self, domain, locals, title: @title), locals)
    end

    private

    def evaluate(path, context, locals)
      raise NotFound, "view not found: #{path}" unless File.file?(path)

      binding = context.get_binding
      locals.each do |name, value|
        binding.local_variable_set(name, value)
      rescue NameError
        raise ArgumentError,
          "invalid local #{name.inspect} for #{path}: locals keys must be valid Ruby local variable names"
      end
      HTML.safe(Template.new(File.read(path)).result(binding))
    end

    def view_path(domain, view)
      File.join(@root, "app", "domains", domain, "views", "#{view}.erb")
    end

    def error_path(status)
      File.join(@root, "app", "errors", "#{Integer(status)}.erb")
    end

    def layout_path(layout)
      File.join(@root, "app", "layouts", "#{layout}.erb")
    end

    class ViewContext
      include ERB::Util

      def initialize(renderer, domain, locals, title: "Hacienda")
        @renderer = renderer
        @domain = domain
        @locals = locals
        @default_title = title.to_s
      end

      def component(name, **locals)
        @renderer.component(@domain, name, @locals.merge(locals))
      end

      def partial(name, **locals)
        @renderer.partial(@domain, name, @locals.merge(locals))
      end

      def csrf_field(context)
        safe_html %(<input type="hidden" name="_csrf" value="#{html_escape(context.csrf_token)}">)
      end

      def csp_nonce(context)
        safe_html html_escape(context.csp_nonce)
      end

      def flash_messages(context)
        return safe_html("") unless context.flash.any?

        messages = context.flash.map do |type, message|
          css_class = type.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")
          role = type.to_s == "alert" || type.to_s == "error" ? "alert" : "status"

          %(<p class="flash flash-#{html_escape(css_class)}" role="#{role}">#{html_escape(message)}</p>)
        end.join

        safe_html %(<div class="flash-messages">#{messages}</div>)
      end

      def navigation_page(content, context:)
        configured = context.application&.navigation&.page_attributes || {}
        attributes = configured.merge(id: "hacienda-page", "data-hacienda-page": true)
        safe_html %(<div#{tag_attributes(attributes)}>#{flash_messages(context)}#{content}</div>)
      end

      def page_title(value = UNDEFINED)
        @page_title = value.to_s unless value.equal?(UNDEFINED)
        @page_title || @default_title
      end

      def document_title
        safe_html html_escape(page_title)
      end

      def hacienda_navigation(context)
        navigation = context.application&.navigation
        return safe_html("") unless navigation&.enabled?

        attributes = {
          type: "module",
          src: asset_path("hacienda-navigation.js"),
          "data-hacienda-navigation": true,
          "data-prefetch": navigation.prefetch || "off",
          "data-cache-size": navigation.cache_size,
          "data-cache-ttl": navigation.cache_ttl
        }
        safe_html "<script#{tag_attributes(attributes)}></script>"
      end

      def cache_fragment(key, context:, expires_in: nil, &block)
        raise ArgumentError, "cache_fragment requires a block" unless block

        html = context.cache.fetch(["fragment", key], expires_in:) do
          value = block.call
          value.is_a?(SafeHTML) ? value.to_s : HTML.escape(value).to_s
        end
        safe_html html
      end

      def error_messages(errors)
        messages = if errors.respond_to?(:full_messages)
          errors.full_messages
        else
          Array(errors)
        end.compact

        return safe_html("") if messages.empty?

        paragraphs = messages.map { |message| %(<p>#{html_escape(message)}</p>) }.join
        safe_html %(<div class="errors" role="alert">#{paragraphs}</div>)
      end

      def path(pattern, **params)
        used = []
        expanded = pattern.to_s.gsub(/:([a-zA-Z_]\w*)/) do
          key = Regexp.last_match(1).to_sym
          raise KeyError, "missing path param: #{key}" unless params.key?(key)

          used << key
          Rack::Utils.escape_path(params.fetch(key).to_s)
        end

        query_params = params.reject { |key, value| used.include?(key) || value.nil? }
        query_params.empty? ? expanded : "#{expanded}?#{Rack::Utils.build_nested_query(query_params)}"
      end

      def link(label, href, **attributes)
        reject_unsafe_url!(href)
        safe_html %(<a href="#{html_escape(href)}"#{tag_attributes(attributes)}>#{html_escape(label)}</a>)
      end
      alias link_to link

      def button(label, type: "button", **attributes)
        safe_html %(<button#{tag_attributes({type: type}.merge(attributes))}>#{html_escape(label)}</button>)
      end

      def button_to(label, action, method: "post", context:, form: {}, button: {}, **attributes)
        form_attributes = attributes.merge(form)

        safe_html [
          form_start(action, method:, context:, **form_attributes),
          button(label, type: "submit", **button),
          form_end
        ].join
      end

      def form_start(action, method: "post", context: nil, **attributes)
        reject_unsafe_url!(action)
        requested_method = method.to_s.downcase
        html_method = requested_method == "get" ? "get" : "post"
        html = %(<form method="#{html_method}" action="#{html_escape(action)}"#{tag_attributes(attributes)}>)
        html += csrf_field(context) if html_method == "post" && context
        html += method_field(requested_method) unless ["get", "post"].include?(requested_method)
        safe_html html
      end

      def form_end
        safe_html "</form>"
      end

      def method_field(method)
        method = method.to_s.downcase
        return safe_html("") if ["get", "post"].include?(method)

        safe_html %(<input type="hidden" name="_method" value="#{html_escape(method)}">)
      end

      def asset_path(source)
        Assets.path(source)
      end

      def stylesheet_link(source, media: nil, nonce: false, context: nil)
        attributes = %(rel="stylesheet" href="#{html_escape(asset_path(source))}")
        attributes += %( media="#{html_escape(media)}") if media
        attributes += %( nonce="#{html_escape(nonce_value(nonce, context))}") if nonce
        safe_html "<link #{attributes}>"
      end

      def javascript_include(source, **options)
        attributes = %(src="#{html_escape(asset_path(source))}")
        attributes += %( type="module") if options[:module]
        attributes += " defer" if options[:defer]
        attributes += %( nonce="#{html_escape(nonce_value(options[:nonce], options[:context]))}") if options[:nonce]
        safe_html "<script #{attributes}></script>"
      end

      def h(value)
        safe_html html_escape(value)
      end

      def raw(value)
        safe_html value
      end

      def get_binding
        binding
      end

      UNSAFE_URL_SCHEMES = %w[javascript vbscript data].freeze

      private

      # Escaping alone can't stop a javascript: href from executing when an
      # app interpolates user data into a link, so reject those schemes.
      # Browsers ignore ASCII control characters and spaces when parsing the
      # scheme, so strip them before matching.
      def reject_unsafe_url!(url)
        scheme = url.to_s.gsub(/[\x00-\x20]/, "")[/\A([a-zA-Z][a-zA-Z0-9+.-]*):/, 1]
        return unless scheme && UNSAFE_URL_SCHEMES.include?(scheme.downcase)

        raise ArgumentError, "refusing to render link to unsafe URL: #{url.inspect}"
      end

      def nonce_value(value, context)
        return value unless value == true
        raise ArgumentError, "nonce: true requires context:" unless context

        context.csp_nonce
      end

      def safe_html(value)
        HTML.safe(value)
      end

      def tag_attributes(attributes)
        compacted = attributes.filter_map do |name, value|
          next if value.nil? || value == false

          attribute = attribute_name(name)
          next attribute if value == true

          %(#{attribute}="#{html_escape(attribute_value(value))}")
        end

        compacted.empty? ? "" : " #{compacted.join(" ")}"
      end

      def attribute_name(name)
        name.to_s.tr("_", "-")
      end

      def attribute_value(value)
        case value
        when Array
          value.flatten.compact.join(" ")
        else
          value.to_s
        end
      end
    end
  end
end
