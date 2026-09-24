module Lookbook
  # Transport-independent MCP (JSON-RPC 2.0) message handling.
  #
  # Used by the HTTP endpoint, the stdio server and the static docs server.
  class McpProtocol
    PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze

    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603

    class RpcError < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    # @param tools [#call] Returns the list of enabled McpTool objects
    # @param resources [Array<McpResource>, #call] Resources, or a callable returning them
    # @param server_info [Hash] `name`, `title` and `version`
    # @param instructions [String] Server instructions for the agent
    # @param logger [Logger, nil]
    def initialize(tools:, resources: [], server_info: {}, instructions: nil, logger: nil)
      @tools = tools
      @resources = resources
      @server_info = server_info
      @instructions = instructions
      @logger = logger
    end

    def tools
      @tools.call
    end

    def resources
      @resources.respond_to?(:call) ? @resources.call : @resources
    end

    # Handles a raw JSON payload (a single message or a batch).
    #
    # @return [Array(Integer, Object)] HTTP-style status and the response body
    #   (nil when there is nothing to send back)
    def handle_json(json, context = {})
      payload = JSON.parse(json)
    rescue JSON::ParserError
      [400, error_response(nil, PARSE_ERROR, "Parse error")]
    else
      messages = payload.is_a?(Array) ? payload : [payload]
      return [400, error_response(nil, INVALID_REQUEST, "Invalid request")] if messages.empty?

      responses = messages.filter_map { |message| handle_message(message, context) }

      if responses.empty?
        [202, nil]
      else
        [200, payload.is_a?(Array) ? responses : responses.first]
      end
    end

    # Handles a single decoded JSON-RPC message.
    #
    # @return [Hash, nil] The response, or nil for notifications
    def handle_message(message, context = {})
      unless message.is_a?(Hash) && message["jsonrpc"] == "2.0" && message["method"].is_a?(String)
        return error_response(message.is_a?(Hash) ? message["id"] : nil, INVALID_REQUEST, "Invalid request")
      end

      id = message["id"]
      notification = !message.key?("id")
      params = message["params"].is_a?(Hash) ? message["params"] : {}

      result = dispatch(message["method"], params, context)
      notification ? nil : {jsonrpc: "2.0", id: id, result: result}
    rescue RpcError => e
      notification ? nil : error_response(id, e.code, e.message)
    rescue => e
      log_error(e)
      notification ? nil : error_response(id, INTERNAL_ERROR, e.message)
    end

    # Runs a newline-delimited JSON-RPC loop (the MCP stdio transport).
    def run_stdio(input: $stdin, output: $stdout, context: {})
      output.sync = true if output.respond_to?(:sync=)

      input.each_line do |line|
        next if line.strip.empty?

        _status, body = handle_json(line, context)
        output.puts(JSON.generate(body)) if body
      end
    end

    private

    def dispatch(method, params, context)
      case method
      when "initialize" then initialize_result(params)
      when "ping" then {}
      when /\Anotifications\// then {}
      when "tools/list" then {tools: tools.map { |tool| tool.definition(context) }}
      when "tools/call" then call_tool(params, context)
      when "resources/list" then {resources: resources.map(&:listing)}
      when "resources/read" then read_resource(params, context)
      when "prompts/list" then {prompts: []}
      else raise RpcError.new(METHOD_NOT_FOUND, "Method not found: #{method}")
      end
    end

    def initialize_result(params)
      requested = params["protocolVersion"]
      {
        protocolVersion: PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first,
        capabilities: {tools: {listChanged: false}, resources: {listChanged: false}, prompts: {listChanged: false}},
        serverInfo: @server_info,
        instructions: @instructions
      }.compact
    end

    def call_tool(params, context)
      tool = tools.find { |t| t.name == params["name"].to_s }
      raise RpcError.new(INVALID_PARAMS, "Unknown tool: #{params["name"]}") unless tool

      arguments = params["arguments"].is_a?(Hash) ? params["arguments"] : {}
      result = tool.call(arguments, context)
      tool_result(result.text, structured_content: result.structured_content)
    rescue McpToolError => e
      tool_result(e.message, error: true)
    rescue RpcError
      raise
    rescue => e
      log_error(e)
      tool_result("#{e.class}: #{e.message}", error: true)
    end

    def tool_result(text, error: false, structured_content: nil)
      {content: [{type: "text", text: text}], structuredContent: structured_content, isError: error}.compact
    end

    def read_resource(params, context)
      resource = resources.find { |r| r.uri == params["uri"] }
      raise RpcError.new(INVALID_PARAMS, "Unknown resource: #{params["uri"]}") unless resource

      {contents: [resource.read(context)]}
    end

    def error_response(id, code, message)
      {jsonrpc: "2.0", id: id, error: {code: code, message: message}}
    end

    def log_error(error)
      @logger&.error("[lookbook-mcp] #{error.class}: #{error.message}")
    end
  end
end
