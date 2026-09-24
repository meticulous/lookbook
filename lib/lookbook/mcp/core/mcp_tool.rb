module Lookbook
  # Raised by MCP tool handlers to return an error result to the agent.
  # The message is shown to the agent as-is.
  class McpToolError < StandardError; end

  # An MCP tool definition. The handler is called with the tool arguments
  # (a Hash with string keys) and a context Hash, and returns a String or
  # an McpTool::Result (text plus structured content for MCP Apps views).
  McpTool = Struct.new(:name, :toolset, :description, :input_schema, :handler, :meta, keyword_init: true) do
    def definition(context = {})
      tool_meta = meta.respond_to?(:call) ? meta.call(context) : meta
      {
        name: name,
        description: description,
        inputSchema: input_schema || {type: "object", properties: {}},
        _meta: tool_meta.presence
      }.compact
    end

    # @return [McpTool::Result]
    def call(arguments, context = {})
      result = handler.call(arguments, context)
      result.is_a?(McpTool::Result) ? result : McpTool::Result.new(text: result.to_s)
    end
  end

  McpTool::Result = Struct.new(:text, :structured_content, keyword_init: true)

  # An MCP resource. The loader returns the resource text for a request context;
  # `meta` (a Hash or a callable taking the context) is returned as `_meta`.
  McpResource = Struct.new(:uri, :name, :mime_type, :loader, :meta, keyword_init: true) do
    def self.json(uri, &loader)
      new(uri: uri, name: uri.split("/").last, mime_type: "application/json", loader: ->(context) { JSON.generate(loader.call(context)) })
    end

    def listing
      {uri: uri, name: name, mimeType: mime_type}
    end

    def read(context = {})
      resource_meta = meta.respond_to?(:call) ? meta.call(context) : meta
      {uri: uri, mimeType: mime_type, text: loader.call(context), _meta: resource_meta.presence}.compact
    end
  end
end
