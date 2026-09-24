module Lookbook
  # Raised by MCP tool handlers to return an error result to the agent.
  # The message is shown to the agent as-is.
  class McpToolError < StandardError; end

  # An MCP tool definition. The handler is called with the tool arguments
  # (a Hash with string keys) and a context Hash, and must return a String.
  McpTool = Struct.new(:name, :toolset, :description, :input_schema, :handler, keyword_init: true) do
    def definition
      {name: name, description: description, inputSchema: input_schema || {type: "object", properties: {}}}
    end

    def call(arguments, context = {})
      handler.call(arguments, context).to_s
    end
  end
end
