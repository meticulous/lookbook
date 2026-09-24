module Lookbook
  # The MCP docs toolset (`docs-list`, `docs-show`, `docs-show-story`).
  #
  # Works purely from manifest data so it can be served live from a running
  # app or from exported `components.json` / `docs.json` files.
  class McpDocs
    SHOW_SCENARIO_LIMIT = 3

    # @param loader [#call] Given the request context, returns `[components, docs]`
    #   manifest hashes (as produced by McpManifest or read from exported JSON)
    # @return [Array<McpTool>]
    def self.tools(loader)
      [
        McpTool.new(
          name: "docs-list",
          toolset: :docs,
          description: "Returns an index of all components documented in Lookbook (one entry per preview, " \
            "listing the components it renders) plus any documentation pages. " \
            "Call this first to find components to reuse before writing UI.",
          input_schema: {type: "object", properties: {}},
          handler: ->(_args, context) { new(*loader.call(context)).docs_list }
        ),
        McpTool.new(
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
          handler: ->(args, context) { new(*loader.call(context)).docs_show(args["id"]) }
        ),
        McpTool.new(
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
          handler: ->(args, context) { new(*loader.call(context)).docs_show_story(args["id"]) }
        )
      ]
    end

    attr_reader :components, :docs

    # @param components [Hash] The components manifest (`{components: {...}}`)
    # @param docs [Hash] The docs manifest (`{docs: {...}}`)
    def initialize(components, docs)
      @components = deep_symbolize(components).fetch(:components, {}).values
      @docs = deep_symbolize(docs).fetch(:docs, {}).values
    end

    def docs_list
      visible_docs = docs.reject { |doc| doc[:hidden] }

      out = ["# Components", ""]
      if components.empty?
        out << "_No previews found._"
      else
        components.each do |entry|
          rendered = Array(entry[:components]).map { |c| c[:name] }
          line = "- **#{entry[:name]}** (id: `#{entry[:id]}`)"
          line += " renders #{rendered.map { |n| "`#{n}`" }.join(", ")}" if rendered.any?
          line += " — #{first_line(entry[:description])}" if entry[:description]
          out << line
        end
      end

      if visible_docs.any?
        out += ["", "# Docs", ""]
        visible_docs.each { |doc| out << "- **#{doc[:title]}** (id: `#{doc[:id]}`)" }
      end

      out.join("\n")
    end

    def docs_show(ref)
      raise McpToolError, "Missing required argument: id" if ref.blank?

      if (entry = find_component(ref))
        component_markdown(entry)
      elsif (page = find_page(ref))
        ["# #{page[:title]}", "", "Source: `#{page[:path]}`", "URL: #{page[:url]}", "", page[:content]].join("\n")
      else
        raise McpToolError, "No component or page found for '#{ref}'. Use docs-list to see available ids."
      end
    end

    def docs_show_story(ref)
      raise McpToolError, "Missing required argument: id" if ref.blank?

      ref = normalize(ref)
      components.each do |entry|
        scenario = Array(entry[:scenarios]).find { |s| [s[:id], s[:lookup_path]].include?(ref) }
        next unless scenario

        out = ["# #{entry[:name]} / #{scenario[:name]}", ""]
        out << "Preview class: `#{entry[:preview_class]}` (`#{entry[:path]}`)"
        out += scenario_markdown(scenario, heading_level: 2)
        return out.join("\n")
      end

      raise McpToolError, "No scenario found for '#{ref}'. Use docs-show to see scenario ids."
    end

    def find_component(ref)
      ref = normalize(ref)
      components.find { |entry| [entry[:id], entry[:lookup_path], entry[:preview_class]].include?(ref) } ||
        components.find { |entry| entry[:preview_class] == "#{ref}Preview" } ||
        components.find { |entry| Array(entry[:components]).any? { |c| c[:name] == ref } }
    end

    def find_page(ref)
      ref = normalize(ref)
      docs.find { |page| [page[:id], page[:lookup_path]].include?(ref) }
    end

    private

    def component_markdown(entry)
      out = ["# #{entry[:name]}", ""]
      out << "Preview class: `#{entry[:preview_class]}` (`#{entry[:path]}`)"
      out << "Inspect: #{entry[:inspect_url]}"
      out += ["", entry[:description]] if entry[:description]

      Array(entry[:components]).each do |component|
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

      scenarios = Array(entry[:scenarios])
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

    def normalize(ref)
      ref.to_s.strip.delete_prefix("/")
    end

    def first_line(text)
      text.to_s.lines.first.to_s.strip
    end

    def deep_symbolize(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
      when Array then value.map { |v| deep_symbolize(v) }
      else value
      end
    end
  end
end
