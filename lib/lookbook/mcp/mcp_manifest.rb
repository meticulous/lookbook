module Lookbook
  # Builds the machine-readable component and docs manifests
  # that back the MCP docs toolset and the `/manifests/*.json` endpoints.
  #
  # @api private
  class McpManifest
    COMMENT_LINE = /\A\s*#( ?)(.*)\z/

    attr_reader :base_url

    def initialize(base_url: nil)
      @base_url = base_url.to_s.chomp("/")
    end

    def components
      entries = Engine.previews.reject(&:hidden?).map { |preview| preview_entry(preview) }
      {components: entries.index_by { |entry| entry[:id] }}
    end

    def docs
      entries = Engine.pages.map { |page| page_entry(page) }
      {docs: entries.index_by { |entry| entry[:id] }}
    end

    def find_preview(ref)
      ref = ref.to_s.strip.delete_prefix("/")
      previews = Engine.previews.to_a

      previews.find { |preview| [preview.id, preview.lookup_path, preview.preview_class_name].include?(ref) } ||
        previews.find { |preview| preview.preview_class_name == "#{ref}Preview" } ||
        previews.find { |preview| preview.render_targets.any? { |target| target.component? && target.component_class.name == ref } }
    end

    def find_scenario(ref)
      ref = ref.to_s.strip.delete_prefix("/")
      Engine.previews.each do |preview|
        scenario = flat_scenarios(preview).find { |s| [s.id, s.lookup_path].include?(ref) }
        return scenario if scenario
      end
      nil
    end

    def find_page(ref)
      ref = ref.to_s.strip.delete_prefix("/")
      Engine.pages.find { |page| [page.id, page.lookup_path].include?(ref) }
    end

    def preview_entry(preview)
      scenarios = flat_scenarios(preview).reject(&:hidden?)
      {
        id: preview.id,
        name: preview.label,
        lookup_path: preview.lookup_path,
        preview_class: preview.preview_class_name,
        path: relative_path(preview.file_path),
        description: preview.notes.presence,
        inspect_url: url(preview.inspect_path),
        components: preview.render_targets.map { |target| render_target_entry(target) },
        scenarios: scenarios.map { |scenario| scenario_entry(scenario) }
      }.compact
    end

    def scenario_entry(scenario)
      group = scenario.group.presence
      {
        id: scenario.id,
        name: scenario.label,
        lookup_path: scenario.lookup_path,
        group: group,
        description: scenario.notes.presence,
        params: scenario.tags(:param).uniq(&:name).map { |tag| param_entry(tag) },
        snippet: scenario.source,
        snippet_lang: scenario.source_lang[:name].to_s,
        inspect_url: url(scenario.inspect_path),
        preview_url: url(scenario.preview_path)
      }.compact
    end

    def render_target_entry(target)
      entry = {
        name: target.component? ? target.component_class.name : target.name,
        type: target.type.to_s,
        path: relative_path(target.file_path),
        template_path: (relative_path(target.template_file_path) if target.component? && target.template_file_path)
      }

      if target.component?
        klass = target.component_class
        entry[:description] = class_description(target.file_path, klass.name)
        entry[:arguments] = initialize_arguments(target.file_path, klass)
        entry[:slots] = slots(klass)
      end

      entry.compact
    end

    def page_entry(page)
      {
        id: page.id,
        title: page.title,
        lookup_path: page.lookup_path,
        path: relative_path(page.file_path),
        url: url(page.url_path),
        hidden: page.hidden?,
        content: page.content.to_s.strip
      }
    end

    private

    def flat_scenarios(preview)
      preview.scenarios.flat_map do |scenario|
        scenario.is_a?(ScenarioGroupEntity) ? scenario.scenarios.to_a : [scenario]
      end
    end

    def param_entry(tag)
      param = Param.from_tag(tag)
      {
        name: param.name.to_s,
        type: param.value_type.to_s,
        input: param.input.to_s,
        description: param.description.presence,
        default: safe_value(param.value_default),
        options: param.input_options.to_h[:choices].presence
      }.compact
    rescue => e
      {name: tag.name.to_s, error: e.message}
    end

    def initialize_arguments(file_path, klass)
      return [] unless klass.instance_methods(false).include?(:initialize) ||
        klass.private_instance_methods(false).include?(:initialize)

      param_docs = method_param_docs(file_path, "initialize")
      klass.instance_method(:initialize).parameters.filter_map do |kind, name|
        next if name.nil? || kind == :block

        {
          name: name.to_s,
          kind: kind.to_s,
          required: [:req, :keyreq].include?(kind),
          description: param_docs[name.to_s]
        }.compact
      end
    end

    def slots(klass)
      return [] unless klass.respond_to?(:registered_slots)

      klass.registered_slots.map do |name, config|
        config = config.to_h
        {
          name: name.to_s,
          collection: config[:collection] ? true : false,
          renderable: config[:renderable]&.to_s
        }.compact
      end
    rescue
      []
    end

    def class_description(file_path, class_name)
      short_name = class_name.to_s.demodulize
      comment_before(file_path, /^\s*class\s+(?:\S+::)?#{Regexp.escape(short_name)}\b/)
    end

    def method_param_docs(file_path, method_name)
      comment = comment_before(file_path, /^\s*def\s+#{Regexp.escape(method_name)}\b/, raw: true).to_s
      comment.scan(/@param\s+\[?[^\]\s]*\]?\s*(\w+)\s*(.*)$/).to_h do |name, desc|
        [name, desc.strip.presence]
      end.compact
    end

    # Returns the contiguous comment block directly above the first line matching `pattern`.
    def comment_before(file_path, pattern, raw: false)
      return unless file_path && File.exist?(file_path)

      lines = File.readlines(file_path, chomp: true)
      index = lines.index { |line| line.match?(pattern) }
      return unless index

      comment = []
      (index - 1).downto(0) do |i|
        match = lines[i].match(COMMENT_LINE)
        break unless match
        comment.unshift(match[2])
      end

      text = raw ? comment : comment.reject { |line| line.strip.start_with?("@") }
      text.join("\n").strip.presence
    end

    def safe_value(value)
      case value
      when nil, String, Numeric, TrueClass, FalseClass then value
      when Symbol then value.to_s
      else value.inspect
      end
    end

    def relative_path(path)
      return if path.blank?

      Pathname(path).relative_path_from(Rails.root).to_s
    rescue ArgumentError
      path.to_s
    end

    def url(path)
      "#{base_url}#{path}"
    end
  end
end
