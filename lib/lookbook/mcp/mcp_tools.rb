module Lookbook
  # Built-in tools exposed by the Lookbook MCP server.
  #
  # Tool names and toolsets mirror Storybook's MCP addon
  # (`docs-list`, `docs-show`, `docs-show-story`) so agent
  # instructions written for one translate to the other.
  #
  # @api private
  class McpTools
    Tool = Struct.new(:name, :toolset, :description, :input_schema, :handler, keyword_init: true) do
      def definition
        {name: name, description: description, inputSchema: input_schema}
      end
    end

    class ToolError < StandardError; end

    DEFAULT_INSTRUCTIONS_PATH = File.expand_path("preview_instructions.md", __dir__)
    SHOW_SCENARIO_LIMIT = 3
    RENDER_MAX_LENGTH = 20_000

    class << self
      def all
        @_all ||= [
          Tool.new(
            name: "docs-list",
            toolset: :docs,
            description: "Returns an index of all components documented in Lookbook (one entry per preview, " \
              "listing the components it renders) plus any documentation pages. " \
              "Call this first to find components to reuse before writing UI.",
            input_schema: {type: "object", properties: {}},
            handler: ->(_args, context) { new(context).docs_list }
          ),
          Tool.new(
            name: "docs-show",
            toolset: :docs,
            description: "Returns detailed documentation for a component: its description, constructor arguments, " \
              "slots, preview params, the first #{SHOW_SCENARIO_LIMIT} preview scenarios with source, and an index of the rest. " \
              "Also returns the content of a documentation page when given a page id.",
            input_schema: {
              type: "object",
              properties: {
                id: {
                  type: "string",
                  description: "A preview id or lookup path from docs-list, a preview class name, a component class name, or a page id."
                }
              },
              required: ["id"]
            },
            handler: ->(args, context) { new(context).docs_show(args["id"]) }
          ),
          Tool.new(
            name: "docs-show-story",
            toolset: :docs,
            description: "Returns the full source, params and notes for a single preview scenario. " \
              "Use when docs-show does not include enough detail about a specific scenario.",
            input_schema: {
              type: "object",
              properties: {
                id: {type: "string", description: "A scenario id or lookup path, as listed by docs-show."}
              },
              required: ["id"]
            },
            handler: ->(args, context) { new(context).docs_show_story(args["id"]) }
          ),
          Tool.new(
            name: "get-preview-instructions",
            toolset: :dev,
            description: "Returns instructions for writing Lookbook preview files in this project. " \
              "Call this before creating or updating previews.",
            input_schema: {type: "object", properties: {}},
            handler: ->(_args, context) { new(context).preview_instructions }
          ),
          Tool.new(
            name: "previews-show",
            toolset: :dev,
            description: "Returns links to view preview scenarios in Lookbook: the inspector URL (with source, params and " \
              "notes panels) and the standalone preview URL. Share these with the user so they can check your work.",
            input_schema: {
              type: "object",
              properties: {
                ids: {
                  type: "array",
                  items: {type: "string"},
                  description: "Scenario or preview ids/lookup paths, as listed by docs-show or previews-find-by-component."
                },
                params: {
                  type: "object",
                  description: "Optional preview param values (from the scenario's @param tags) to apply to every link.",
                  additionalProperties: true
                }
              },
              required: ["ids"]
            },
            handler: ->(args, context) { new(context).previews_show(args["ids"], args["params"]) }
          ),
          Tool.new(
            name: "previews-find-by-component",
            toolset: :dev,
            description: "Finds the previews and scenarios that render a component. Accepts component class names or " \
              "paths to component Ruby files, templates or partials (relative to the app root).",
            input_schema: {
              type: "object",
              properties: {
                components: {
                  type: "array",
                  items: {type: "string"},
                  description: "Component class names (e.g. `ButtonComponent`) or file paths (e.g. `app/components/button_component.rb`)."
                }
              },
              required: ["components"]
            },
            handler: ->(args, context) { new(context).previews_find_by_component(args["components"]) }
          ),
          Tool.new(
            name: "render-scenario",
            toolset: :dev,
            description: "Renders a preview scenario and returns its HTML output, or the error raised while rendering it. " \
              "Use this to check that a component renders what you expect with given params, without a browser.",
            input_schema: {
              type: "object",
              properties: {
                id: {type: "string", description: "A scenario or preview id/lookup path."},
                params: {
                  type: "object",
                  description: "Optional preview param values (from the scenario's @param tags).",
                  additionalProperties: true
                },
                full_page: {
                  type: "boolean",
                  description: "Return the whole document including the preview layout. Defaults to false (body contents only)."
                },
                beautify: {type: "boolean", description: "Reformat the HTML for readability. Defaults to false."},
                max_length: {
                  type: "integer",
                  description: "Maximum number of characters of HTML to return. Defaults to #{RENDER_MAX_LENGTH}."
                }
              },
              required: ["id"]
            },
            handler: ->(args, context) { new(context).render_scenario(args["id"], args) }
          )
        ].freeze
      end

      def enabled
        toolsets = Lookbook.config.mcp.toolsets.to_h.transform_keys(&:to_sym)
        all.select { |tool| toolsets.fetch(tool.toolset, true) }
      end

      def find(name)
        enabled.find { |tool| tool.name == name.to_s }
      end
    end

    attr_reader :manifest, :context

    def initialize(context = {})
      @context = context
      @manifest = McpManifest.new(base_url: context[:base_url])
    end

    def docs_list
      components = manifest.components[:components].values
      docs = manifest.docs[:docs].values.reject { |doc| doc[:hidden] }

      out = ["# Components", ""]
      if components.empty?
        out << "_No previews found._"
      else
        components.each do |entry|
          rendered = entry[:components].map { |c| c[:name] }
          line = "- **#{entry[:name]}** (id: `#{entry[:id]}`)"
          line += " renders #{rendered.map { |n| "`#{n}`" }.join(", ")}" if rendered.any?
          line += " — #{first_line(entry[:description])}" if entry[:description]
          out << line
        end
      end

      if docs.any?
        out += ["", "# Docs", ""]
        docs.each { |doc| out << "- **#{doc[:title]}** (id: `#{doc[:id]}`)" }
      end

      out.join("\n")
    end

    def docs_show(ref)
      raise ToolError, "Missing required argument: id" if ref.blank?

      if (preview = manifest.find_preview(ref))
        component_markdown(manifest.preview_entry(preview))
      elsif (page = manifest.find_page(ref))
        entry = manifest.page_entry(page)
        ["# #{entry[:title]}", "", "Source: `#{entry[:path]}`", "URL: #{entry[:url]}", "", entry[:content]].join("\n")
      else
        raise ToolError, "No component or page found for '#{ref}'. Use docs-list to see available ids."
      end
    end

    def docs_show_story(ref)
      raise ToolError, "Missing required argument: id" if ref.blank?

      scenario = manifest.find_scenario(ref)
      raise ToolError, "No scenario found for '#{ref}'. Use docs-show to see scenario ids." unless scenario

      entry = manifest.scenario_entry(scenario)
      preview_entry = manifest.preview_entry(scenario.preview)

      out = ["# #{preview_entry[:name]} / #{entry[:name]}", ""]
      out << "Preview class: `#{preview_entry[:preview_class]}` (`#{preview_entry[:path]}`)"
      out += scenario_markdown(entry, heading_level: 2)
      out.join("\n")
    end

    def preview_instructions
      path = Lookbook.config.mcp.instructions_path.presence
      path = Rails.root.join(path) if path && !Pathname(path).absolute?
      File.read(path || DEFAULT_INSTRUCTIONS_PATH)
    end

    def previews_show(refs, params = nil)
      refs = Array(refs).map(&:to_s).reject(&:blank?)
      raise ToolError, "Missing required argument: ids" if refs.empty?

      query = params.to_h.to_query.presence
      out = []
      missing = []

      refs.each do |ref|
        target = manifest.find_renderable(ref)
        next missing << ref unless target

        out += ["", "## #{target.preview.label} / #{target.label}", ""]
        out << "- Inspect: #{with_query(manifest.url(target.inspect_path), query)}"
        out << "- Preview: #{with_query(manifest.url(target.preview_path), query)}"
      end

      out += ["", "Not found: #{missing.map { |m| "`#{m}`" }.join(", ")}. Use docs-list or docs-show to find ids."] if missing.any?
      raise ToolError, out.join("\n").strip if missing.size == refs.size

      out.join("\n").strip
    end

    def previews_find_by_component(refs)
      refs = Array(refs).map(&:to_s).reject(&:blank?)
      raise ToolError, "Missing required argument: components" if refs.empty?

      out = []
      refs.each do |ref|
        out += ["", "## `#{ref}`", ""]
        results = manifest.find_by_component(ref)

        if results.empty?
          out << "No previews render this component. Call get-preview-instructions to write one."
          next
        end

        results.each do |preview, scenarios|
          out << "- **#{preview.label}** (id: `#{preview.id}`, `#{preview.preview_class_name}`)"
          scenarios.each do |scenario|
            out << "  - #{scenario.label} (id: `#{scenario.lookup_path}`) #{manifest.url(scenario.preview_path)}"
          end
        end
      end

      out.join("\n").strip
    end

    def render_scenario(ref, options = {})
      raise ToolError, "Missing required argument: id" if ref.blank?

      target = manifest.find_renderable(ref)
      raise ToolError, "No scenario found for '#{ref}'. Use docs-show to see scenario ids." unless target

      renderer = McpRenderer.new(base_url: context[:request_base_url] || context[:base_url])
      result = renderer.call(target, params: options["params"])
      heading = "#{target.preview.label} / #{target.label} (`#{target.lookup_path}`)"

      unless result.success?
        raise ToolError, "Rendering #{heading} failed (HTTP #{result.status}):\n\n#{result.error.to_s.strip}"
      end

      html = options["full_page"] ? result.html.to_s.strip : McpRenderer.body_content(result.html)
      html = CodeBeautifier.call(html) if options["beautify"]

      max_length = options["max_length"].to_i
      max_length = RENDER_MAX_LENGTH unless max_length.positive?
      truncated = html.length > max_length

      out = ["Rendered #{heading}", "Preview: #{with_query(manifest.url(target.preview_path), options["params"].to_h.to_query.presence)}"]
      out << "Output truncated to #{max_length} of #{html.length} characters." if truncated
      out += ["", "```html", html[0, max_length], "```"]
      out.join("\n")
    end

    private

    def with_query(url, query)
      query ? "#{url}?#{query}" : url
    end

    def component_markdown(entry)
      out = ["# #{entry[:name]}", ""]
      out << "Preview class: `#{entry[:preview_class]}` (`#{entry[:path]}`)"
      out << "Inspect: #{entry[:inspect_url]}"
      out += ["", entry[:description]] if entry[:description]

      entry[:components].each do |component|
        kind = (component[:type] == "component") ? "Component" : "Template"
        out += ["", "## #{kind}: `#{component[:name]}`", ""]
        out << "Source: `#{component[:path]}`"
        out << "Template: `#{component[:template_path]}`" if component[:template_path]
        out += ["", component[:description]] if component[:description]

        if component[:arguments].present?
          out += ["", "### Arguments", ""]
          component[:arguments].each do |arg|
            line = "- `#{arg[:name]}` (#{arg[:kind]}#{", required" if arg[:required]})"
            line += " — #{arg[:description]}" if arg[:description]
            out << line
          end
        end

        if component[:slots].present?
          out += ["", "### Slots", ""]
          component[:slots].each do |slot|
            out << "- `#{slot[:name]}`#{" (collection)" if slot[:collection]}"
          end
        end
      end

      scenarios = entry[:scenarios]
      shown = scenarios.first(SHOW_SCENARIO_LIMIT)
      rest = scenarios.drop(SHOW_SCENARIO_LIMIT)

      if shown.any?
        out += ["", "## Scenarios"]
        shown.each { |scenario| out += scenario_markdown(scenario, heading_level: 3) }
      end

      if rest.any?
        out += ["", "## Other scenarios", "", "Use docs-show-story with one of these ids for details:", ""]
        rest.each { |scenario| out << "- #{scenario[:name]} (id: `#{scenario[:lookup_path]}`)" }
      end

      out.join("\n")
    end

    def scenario_markdown(entry, heading_level:)
      hashes = "#" * heading_level
      out = ["", "#{hashes} #{entry[:name]}", ""]
      out << "id: `#{entry[:lookup_path]}`"
      out << "Group: #{entry[:group]}" if entry[:group]
      out << "Preview: #{entry[:preview_url]}"
      out += ["", entry[:description]] if entry[:description]

      if entry[:params].present?
        out += ["", "Params:", ""]
        entry[:params].each do |param|
          line = "- `#{param[:name]}` (#{param[:type]}, input: #{param[:input]})"
          line += " default: `#{param[:default].is_a?(String) ? param[:default].inspect : param[:default]}`" unless param[:default].nil?
          line += " — #{param[:description]}" if param[:description]
          out << line
        end
      end

      out += ["", "```#{entry[:snippet_lang]}", entry[:snippet], "```"]
    end

    def first_line(text)
      text.to_s.lines.first.to_s.strip
    end
  end
end
