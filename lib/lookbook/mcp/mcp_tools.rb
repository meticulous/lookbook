module Lookbook
  # Tools exposed by the live Lookbook MCP server.
  #
  # Tool names and toolsets mirror Storybook's MCP addon so agent
  # instructions written for one translate to the other. The docs
  # toolset lives in McpDocs so it can also be served from exported
  # manifests.
  #
  # @api private
  class McpTools
    ToolError = McpToolError

    DEFAULT_INSTRUCTIONS_PATH = File.expand_path("preview_instructions.md", __dir__)
    RENDER_MAX_LENGTH = 20_000
    CHECK_ERROR_LINES = 8
    COMPONENT_FILE_PATTERN = /\.(rb|erb|haml|slim)\z/

    ARRAY_OF_STRINGS = {type: "array", items: {type: "string"}}.freeze
    PARAMS_SCHEMA = {
      type: "object",
      description: "Optional preview param values (from the scenario's @param tags).",
      additionalProperties: true
    }.freeze

    class << self
      def all
        [*built_in, *Engine.mcp_tools]
      end

      def enabled
        toolsets = Lookbook.config.mcp.toolsets.to_h.transform_keys(&:to_sym)
        all.select { |tool| toolsets.fetch(tool.toolset, true) }
      end

      def find(name)
        enabled.find { |tool| tool.name == name.to_s }
      end

      private

      def built_in
        @_built_in ||= [
          *McpDocs.tools(->(context) {
            manifest = McpManifest.new(base_url: context[:base_url])
            [manifest.components, manifest.docs]
          }),
          McpTool.new(
            name: "get-preview-instructions",
            toolset: :dev,
            description: "Returns instructions for writing Lookbook preview files in this project. " \
              "Call this before creating or updating previews.",
            input_schema: {type: "object", properties: {}},
            handler: ->(_args, context) { new(context).preview_instructions }
          ),
          McpTool.new(
            name: "previews-show",
            toolset: :dev,
            description: "Returns links to view preview scenarios in Lookbook: the inspector URL (with source, params and " \
              "notes panels) and the standalone preview URL. Share these with the user so they can check your work.",
            input_schema: {
              type: "object",
              properties: {
                ids: ARRAY_OF_STRINGS.merge(description: "Scenario or preview ids/lookup paths, as listed by docs-show or previews-find-by-component."),
                params: PARAMS_SCHEMA.merge(description: "Optional preview param values to apply to every link.")
              },
              required: ["ids"]
            },
            handler: ->(args, context) { new(context).previews_show(args["ids"], args["params"]) }
          ),
          McpTool.new(
            name: "previews-find-by-component",
            toolset: :dev,
            description: "Finds the previews and scenarios that render a component. Accepts component class names or " \
              "paths to component Ruby files, templates or partials (relative to the app root).",
            input_schema: {
              type: "object",
              properties: {
                components: ARRAY_OF_STRINGS.merge(description: "Component class names (e.g. `ButtonComponent`) or file paths (e.g. `app/components/button_component.rb`).")
              },
              required: ["components"]
            },
            handler: ->(args, context) { new(context).previews_find_by_component(args["components"]) }
          ),
          McpTool.new(
            name: "previews-changed",
            toolset: :dev,
            description: "Lists previews and scenarios affected by local changes in git (changed preview files and changed " \
              "components, templates or partials they render), plus changed components that have no preview.",
            input_schema: {
              type: "object",
              properties: {
                base: {type: "string", description: "Git ref to compare against. Defaults to HEAD (uncommitted and untracked changes)."}
              }
            },
            handler: ->(args, context) { new(context).previews_changed(args["base"]) }
          ),
          McpTool.new(
            name: "render-scenario",
            toolset: :dev,
            description: "Renders a preview scenario and returns its HTML output, or the error raised while rendering it. " \
              "Use this to check that a component renders what you expect with given params, without a browser.",
            input_schema: {
              type: "object",
              properties: {
                id: {type: "string", description: "A scenario or preview id/lookup path."},
                params: PARAMS_SCHEMA,
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
          ),
          McpTool.new(
            name: "previews-check",
            toolset: :test,
            description: "Renders preview scenarios and reports any that raise errors or render nothing. Checks every " \
              "visible scenario unless ids or components are given. Run this after changing components, then fix and re-run.",
            input_schema: {
              type: "object",
              properties: {
                ids: ARRAY_OF_STRINGS.merge(description: "Scenario or preview ids/lookup paths to check."),
                components: ARRAY_OF_STRINGS.merge(description: "Check every scenario that renders these components (class names or file paths)."),
                changed: {type: "boolean", description: "Check scenarios affected by uncommitted git changes (see previews-changed)."}
              }
            },
            handler: ->(args, context) { new(context).previews_check(args) }
          )
        ].freeze
      end
    end

    attr_reader :manifest, :context

    def initialize(context = {})
      @context = context
      @manifest = McpManifest.new(base_url: context[:base_url])
    end

    def preview_instructions
      path = Lookbook.config.mcp.instructions_path.presence
      path = Rails.root.join(path) if path && !Pathname(path).absolute?
      File.read(path || DEFAULT_INSTRUCTIONS_PATH)
    end

    def previews_show(refs, params = nil)
      refs = string_list(refs)
      raise ToolError, "Missing required argument: ids" if refs.empty?

      query = params.to_h.to_query.presence
      out = []
      missing = []

      refs.each do |ref|
        target = manifest.find_renderable(ref)
        next missing << ref unless target

        out += ["", "## #{target_label(target)}", ""]
        out << "- Inspect: #{with_query(manifest.url(target.inspect_path), query)}"
        out << "- Preview: #{with_query(manifest.url(target.preview_path), query)}"
      end

      out += ["", "Not found: #{missing.map { |m| "`#{m}`" }.join(", ")}. Use docs-list or docs-show to find ids."] if missing.any?
      raise ToolError, out.join("\n").strip if missing.size == refs.size

      out.join("\n").strip
    end

    def previews_find_by_component(refs)
      refs = string_list(refs)
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
          out << preview_line(preview)
          scenarios.each { |scenario| out << scenario_line(scenario) }
        end
      end

      out.join("\n").strip
    end

    def previews_changed(base = nil)
      files = McpGitChanges.new.files(base)
      affected, uncovered = changed_previews(files)

      out = ["Changed files: #{files.size}#{" (compared to #{base})" if base.present?}"]

      if affected.empty?
        out += ["", "No previews are affected by these changes."]
      else
        out += ["", "## Affected previews", ""]
        affected.each do |preview, (scenarios, reasons)|
          out << "#{preview_line(preview)} — #{reasons.to_a.join("; ")}"
          scenarios.each { |scenario| out << scenario_line(scenario) }
        end
      end

      if uncovered.any?
        out += ["", "## Changed components without previews", ""]
        uncovered.each { |path| out << "- `#{path}`" }
      end

      out.join("\n")
    end

    def render_scenario(ref, options = {})
      raise ToolError, "Missing required argument: id" if ref.blank?

      target = manifest.find_renderable(ref)
      raise ToolError, "No scenario found for '#{ref}'. Use docs-show to see scenario ids." unless target

      result = renderer.call(target, params: options["params"])
      heading = "#{target_label(target)} (`#{target.lookup_path}`)"

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

    def previews_check(options = {})
      scenarios, missing = check_targets(options)
      raise ToolError, "Nothing to check: #{missing.map { |m| "`#{m}`" }.join(", ")} not found." if scenarios.empty? && missing.any?
      return "No scenarios to check." if scenarios.empty?

      failures = []
      warnings = []

      scenarios.each do |scenario|
        result = renderer.call(scenario)
        if !result.success?
          failures << [scenario, "HTTP #{result.status}: #{result.error.to_s.strip.lines.first(CHECK_ERROR_LINES).join.strip}"]
        elsif McpRenderer.body_content(result.html).blank?
          warnings << [scenario, "rendered no output"]
        end
      end

      passed = scenarios.size - failures.size
      out = ["Checked #{scenarios.size} #{"scenario".pluralize(scenarios.size)}: #{passed} passed, #{failures.size} failed" \
        "#{", #{warnings.size} with warnings" if warnings.any?}."]

      if failures.any?
        out += ["", "## Failures"]
        failures.each do |scenario, message|
          out += ["", "### #{target_label(scenario)} (id: `#{scenario.lookup_path}`)", "", "```", message, "```"]
        end
      end

      if warnings.any?
        out += ["", "## Warnings", ""]
        warnings.each { |scenario, message| out << "- #{target_label(scenario)} (id: `#{scenario.lookup_path}`): #{message}" }
      end

      out += ["", "Not found: #{missing.map { |m| "`#{m}`" }.join(", ")}"] if missing.any?
      out.join("\n")
    end

    private

    def renderer
      @renderer ||= McpRenderer.new(base_url: context[:request_base_url] || context[:base_url])
    end

    # Returns `[{preview => [scenarios, reasons]}, uncovered_component_paths]`.
    def changed_previews(files)
      affected = Hash.new { |hash, preview| hash[preview] = [Set.new, Set.new] }
      previews = Engine.previews.reject(&:hidden?)
      preview_files = previews.index_by { |preview| manifest.relative_path(preview.file_path) }
      uncovered = []

      files.each do |file|
        if (preview = preview_files[file])
          affected[preview][0].merge(manifest.flat_scenarios(preview).reject(&:hidden?))
          affected[preview][1] << "preview file changed"
          next
        end

        matches = manifest.find_by_component(file)
        matches.each do |match_preview, scenarios|
          affected[match_preview][0].merge(scenarios)
          affected[match_preview][1] << "renders `#{file}`"
        end

        uncovered << file if matches.empty? && component_file?(file)
      end

      [affected.transform_values { |(scenarios, reasons)| [scenarios.to_a, reasons] }, uncovered]
    end

    def component_file?(file)
      return false unless file.match?(COMPONENT_FILE_PATTERN)

      full_path = Rails.root.join(file).to_s
      Engine.component_paths.any? { |dir| full_path.start_with?("#{dir}/") } &&
        Engine.preview_paths.none? { |dir| full_path.start_with?("#{dir}/") }
    end

    def check_targets(options)
      ids = string_list(options["ids"])
      components = string_list(options["components"])
      missing = []

      if ids.empty? && components.empty? && !options["changed"]
        scenarios = Engine.previews.reject(&:hidden?).flat_map do |preview|
          manifest.flat_scenarios(preview).reject(&:hidden?)
        end
        return [renderables(scenarios), missing]
      end

      scenarios = ids.filter_map do |ref|
        manifest.find_renderable(ref).tap { |target| missing << ref unless target }
      end

      components.each do |ref|
        matches = manifest.find_by_component(ref)
        missing << ref if matches.empty?
        scenarios += matches.flat_map(&:last)
      end

      if options["changed"]
        scenarios += changed_previews(McpGitChanges.new.files).first.values.flat_map(&:first)
      end

      [renderables(scenarios), missing]
    end

    # Grouped scenarios are rendered once, as their group.
    def renderables(scenarios)
      scenarios.map { |scenario| manifest.renderable_for(scenario) }.uniq(&:lookup_path)
    end

    def preview_line(preview)
      "- **#{preview.label}** (id: `#{preview.id}`, `#{preview.preview_class_name}`)"
    end

    def scenario_line(scenario)
      "  - #{scenario.label} (id: `#{scenario.lookup_path}`) #{manifest.url(manifest.renderable_for(scenario).preview_path)}"
    end

    def target_label(target)
      "#{target.preview.label} / #{target.label}"
    end

    def string_list(value)
      Array(value).map(&:to_s).reject(&:blank?)
    end

    def with_query(url, query)
      query ? "#{url}?#{query}" : url
    end
  end
end
