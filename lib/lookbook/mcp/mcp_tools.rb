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

    attr_reader :manifest

    def initialize(context = {})
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

    private

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
