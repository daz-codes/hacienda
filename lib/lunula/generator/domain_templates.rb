# frozen_string_literal: true

module Lunula
  class Generator
    module DomainTemplates
      private

      def action_method_template(action, body: "{}")
        "def #{action}(_context, _params)\n#{indent(body, 2)}\nend\n"
      end

      def action_set_template(namespace, body = "", class_name: "Actions")
        methods = body.to_s.rstrip
        [
          "# frozen_string_literal: true\n\n",
          "module #{namespace}\n",
          "  class #{class_name} < Lunula::Actions\n",
          methods.empty? ? "" : "#{indent(methods, 4)}\n",
          "  end\n",
          "end\n"
        ].join
      end

      def append_action_method(actions_file, action_body)
        existing = File.read(actions_file)
        class_end = existing.rindex(/^  end\s*$/)
        raise Error, "could not append action to malformed file: #{actions_file}" unless class_end

        insertion = "\n#{indent(action_body.rstrip, 4)}\n"
        File.write(actions_file, "#{existing[0...class_end]}#{insertion}#{existing[class_end..]}")
      end

      def append_test_method(test_file, method_body)
        existing = File.read(test_file)
        class_end = existing.rindex(/^end\s*$/)
        raise Error, "could not append test to malformed file: #{test_file}" unless class_end

        insertion = "\n#{indent(method_body.rstrip, 2)}\n"
        File.write(test_file, "#{existing[0...class_end]}#{insertion}#{existing[class_end..]}")
      end

      def wrap_domain_module(namespace, body)
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
          #{indent(body.rstrip, 2)}
          end
        RUBY
      end

      def indent(text, spaces)
        padding = " " * spaces
        text.lines.map { |line| line.strip.empty? ? line : "#{padding}#{line}" }.join
      end

      def append_route_example(domain, action, group: nil)
        routes = File.join(domain_root(domain), "routes.rb")
        action_set = group ? ", actions: :#{group}" : ""
        example = <<~RUBY

          # Choose the HTTP verb and path for this action:
          # post "/#{domain}/:id/#{action}", :#{action}#{action_set}
        RUBY
        File.open(routes, "a") { |file| file.write(example) }
      end

      def write_action_test(domain, action, group: nil)
        FileUtils.rm_f(File.join(domain_test_root(domain), ".keep"))
        namespace = camelize(domain)
        class_name = group ? "#{camelize(group)}Actions" : "Actions"
        test_class = "#{namespace}#{class_name}Test"
        path = File.join(
          domain_test_root(domain),
          group ? "#{group}_actions_test.rb" : "actions_test.rb"
        )
        method_body = <<~RUBY
          def test_#{action}_returns_view_locals
            result = #{namespace}::#{class_name}.new.#{action}(nil, Lunula::Params.new({}))

            assert_equal({}, result)
          end
        RUBY

        if File.exist?(path)
          append_test_method(path, method_body)
        else
          write_new(path, <<~RUBY)
            # frozen_string_literal: true

            require_relative "../../test_helper"

            class #{test_class} < Minitest::Test
            #{indent(method_body.rstrip, 2)}
            end
          RUBY
        end
      end

      def rest_routes(domain)
        <<~RUBY
          get "/#{domain}", :index
          get "/#{domain}/new", :new
          post "/#{domain}", :create
          get "/#{domain}/:id", :show
          get "/#{domain}/:id/edit", :edit
          patch "/#{domain}/:id", :update
          delete "/#{domain}/:id", :destroy
        RUBY
      end

      def entity_template(namespace, entity_class)
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{entity_class}
              include Lunula::Attributes
              include Lunula::Validations

              attributes :id, :created_at, :updated_at
              attribute :title, default: ""
              attribute :body, default: ""

              def validate
                errors.add :title, "is required" if title.to_s.strip.empty?
                errors.add :body, "is required" if body.to_s.strip.empty?
              end
            end
          end
        RUBY
      end

      def rest_repository(namespace, entity_class, table)
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            module Repository
              extend Lunula::Repository

              store(
                database: APP.database,
                table: :#{table},
                record: #{entity_class}
              )

              def all(scope = dataset.reverse_order(:created_at))
                super(scope)
              end
            end
          end
        RUBY
      end

      def rest_actions(namespace, entity, entity_class, domain)
        actions = %w[index show new create edit update destroy].map do |action|
          body = rest_action_code(entity, entity_class, domain, action)
          context = body.include?("context.") ? "context" : "_context"
          "def #{action}(#{context}, params)\n#{indent(body, 2)}\nend\n"
        end.join("\n")
        action_set_template(namespace, actions)
      end

      def rest_action_code(entity, entity_class, domain, action)
        case action
        when "index"
          "{#{domain}: Repository.all}"
        when "show"
          "{#{entity}: Repository.find(params[:id])}"
        when "new"
          "{#{entity}: #{entity_class}.new, errors: []}"
        when "create"
          <<~RUBY.chomp
            attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
            #{entity} = #{entity_class}.new(
              title: attributes[:title],
              body: attributes[:body]
            )
            return render(:new, #{entity}:, errors: #{entity}.errors, status: 422) if #{entity}.invalid?

            Repository.save(#{entity})
            context.flash[:notice] = "#{entity_class} created."
            redirect "/#{domain}/\#{#{entity}.id}"
          RUBY
        when "edit"
          "{#{entity}: Repository.find(params[:id]), errors: []}"
        when "update"
          <<~RUBY.chomp
            #{entity} = Repository.find(params[:id])
            attributes = params.permit(:title, :body).transform_values { |value| value.to_s.strip }
            #{entity}.title = attributes[:title]
            #{entity}.body = attributes[:body]
            return render(:edit, #{entity}:, errors: #{entity}.errors, status: 422) if #{entity}.invalid?

            Repository.save(#{entity})
            context.flash[:notice] = "#{entity_class} updated."
            redirect "/#{domain}/\#{#{entity}.id}"
          RUBY
        when "destroy"
          <<~RUBY.chomp
            #{entity} = Repository.find(params[:id])
            Repository.delete(#{entity})
            context.flash[:notice] = "#{entity_class} deleted."
            redirect "/#{domain}"
          RUBY
        end
      end

      def rest_views(domain, entity)
        {
          "index.erb" => <<~ERB,
            <% page_title "#{camelize(domain)}" %>

            <header>
              <h1>#{camelize(domain)}</h1>
              <%= link "New #{entity}", "/#{domain}/new" %>
            </header>

            <% #{domain}.each do |#{entity}| %>
              <%= component :#{entity}_card, #{entity}: #{entity} %>
            <% end %>
          ERB
          "show.erb" => <<~ERB,
            <% page_title #{entity}.title %>

            <article>
              <h1><%= #{entity}.title %></h1>
              <p><%= #{entity}.body %></p>
              <%= link "Edit", path("/#{domain}/:id/edit", id: #{entity}.id) %>
            </article>
          ERB
          "new.erb" => <<~ERB,
            <% page_title "New #{entity}" %>

            <h1>New #{entity}</h1>
            <%= partial :form, #{entity}:, errors:, action: "/#{domain}", method: "post" %>
          ERB
          "edit.erb" => <<~ERB,
            <% page_title "Edit \#{#{entity}.title}" %>

            <h1>Edit #{entity}</h1>
            <%= partial :form,
                  #{entity}:,
                  errors:,
                  action: "/#{domain}/\#{#{entity}.id}",
                  method: "patch" %>
          ERB
          "form.erb" => <<~ERB,
            <%= error_messages errors %>

            <%= form_start action, method:, context: %>

              <label>
                Title
                <input name="title" value="<%= #{entity}.title %>" required>
              </label>

              <label>
                Body
                <textarea name="body" required><%= #{entity}.body %></textarea>
              </label>

              <button type="submit">Save</button>
            <%= form_end %>
          ERB
          "components/_#{entity}_card.erb" => <<~ERB
            <article>
              <h2>
                <%= link #{entity}.title, path("/#{domain}/:id", id: #{entity}.id) %>
              </h2>
            </article>
          ERB
        }
      end

      def rest_migration(table)
        <<~RUBY
          Sequel.migration do
            change do
              create_table(:#{table}) do
                primary_key :id
                String :title, null: false
                String :body, text: true, null: false
                DateTime :created_at, null: false
                DateTime :updated_at, null: false
              end
            end
          end
        RUBY
      end

      def write_rest_tests(domain, namespace, entity, entity_class)
        FileUtils.rm_f(File.join(domain_test_root(domain), ".keep"))
        tests = {
          "#{entity}_test.rb" => rest_entity_test(namespace, entity_class),
          "repository_test.rb" => rest_repository_test(domain, namespace, entity_class),
          "actions_test.rb" => rest_actions_test(domain, namespace, entity)
        }
        tests.each do |name, content|
          path = File.join(domain_test_root(domain), name)
          File.exist?(path) ? File.write(path, content) : write_new(path, content)
        end
      end

      def rest_entity_test(namespace, entity_class)
        <<~RUBY
          # frozen_string_literal: true

          require_relative "../../test_helper"

          class #{namespace}#{entity_class}Test < Minitest::Test
            def test_title_and_body_are_required
              record = #{namespace}::#{entity_class}.new

              refute record.valid?
              assert_includes record.errors.full_messages, "Title is required"
              assert_includes record.errors.full_messages, "Body is required"
            end

            def test_complete_record_is_valid
              record = #{namespace}::#{entity_class}.new(title: "First", body: "Useful body")

              assert record.valid?
            end
          end
        RUBY
      end

      def rest_repository_test(domain, namespace, entity_class)
        <<~RUBY
          # frozen_string_literal: true

          require_relative "../../test_helper"

          class #{namespace}RepositoryTest < Minitest::Test
            def setup
              APP.database[:#{domain}].delete
            end

            def test_saved_records_can_be_found
              record = #{namespace}::#{entity_class}.new(title: "Saved", body: "Repository contract")

              #{namespace}::Repository.save(record)
              found = #{namespace}::Repository.find(record.id)

              assert_equal record.id, found.id
              assert_equal "Saved", found.title
              assert_equal record.id, #{namespace}::Repository.find_by!(title: "Saved").id
              assert_nil #{namespace}::Repository.find_by(title: "Missing")
              assert_raises(Lunula::NotFound) { #{namespace}::Repository.find(0) }
            end
          end
        RUBY
      end

      def rest_actions_test(domain, namespace, entity)
        <<~RUBY
          # frozen_string_literal: true

          require_relative "../../test_helper"

          class #{namespace}ActionsTest < ApplicationTest
            def setup
              super
              database[:#{domain}].delete
            end

            def test_create_redirects_to_the_persisted_record
              post "/#{domain}", {
                _csrf: csrf_token,
                title: "Created through HTTP",
                body: "Domain action contract"
              }

              assert_equal 303, last_response.status
              record = database[:#{domain}].first
              assert_equal "/#{domain}/\#{record[:id]}", last_response["location"]

              get last_response["location"]
              assert_equal 200, last_response.status
              assert_includes last_response.body, "Created through HTTP"
            end
          end
        RUBY
      end

      def migration_template(name)
        <<~RUBY
          # frozen_string_literal: true

          Sequel.migration do
            change do
              # Example:
              # create_table(:#{name.delete_prefix("create_")}) do
              #   primary_key :id
              #   String :title, null: false
              # end
            end
          end
        RUBY
      end

      def migration_path(name)
        directory = File.join(@target, "db", "migrations")
        existing_versions = Dir[File.join(directory, "*.rb")].filter_map do |path|
          File.basename(path)[/\A\d+/]&.to_i
        end
        current_version = Time.now.utc.strftime("%Y%m%d%H%M%S").to_i
        version = [current_version, existing_versions.max.to_i + 1].max
        File.join(directory, "#{version}_#{name}.rb")
      end
    end
  end
end
