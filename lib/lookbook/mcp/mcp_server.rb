module Lookbook
  # Rack endpoint implementing the MCP Streamable HTTP transport
  # (stateless, JSON responses only).
  #
  # Mounted at `<lookbook mount path>/mcp`. Also serves the
  # `/manifests/components.json` and `/manifests/docs.json` endpoints.
  #
  # @api private
  class McpServer
    PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
    SERVER_INSTRUCTIONS = "Lookbook component library for this Rails app. Use docs-list to find existing " \
      "components, docs-show before using any component argument or slot, and get-preview-instructions " \
      "before writing previews. Check your work with render-scenario and share links from previews-show. " \
      "Never guess component arguments that docs-show does not list."

    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32603

    def self.manifest_endpoint(name)
      ->(env) { new.manifest_response(env, name) }
    end

    def call(env)
      request = Rack::Request.new(env)
      return not_found unless enabled?
      return forbidden("Origin not allowed") unless origin_allowed?(request)

      case request.request_method
      when "POST"
        return unauthorized unless authorized?(request)
        handle_post(request)
      when "GET"
        if request.get_header("HTTP_ACCEPT").to_s.include?("text/html")
          [200, {"content-type" => "text/html; charset=utf-8"}, [info_page(request)]]
        else
          method_not_allowed
        end
      else
        method_not_allowed
      end
    end

    def manifest_response(env, name)
      request = Rack::Request.new(env)
      return not_found unless enabled?
      return forbidden("Origin not allowed") unless origin_allowed?(request)
      return unauthorized unless authorized?(request)

      manifest = McpManifest.new(base_url: base_url(request))
      body = (name == :docs) ? manifest.docs : manifest.components
      json_response(200, body)
    end

    private

    def handle_post(request)
      payload = JSON.parse(request.body.read)
    rescue JSON::ParserError
      json_response(400, error_response(nil, PARSE_ERROR, "Parse error"))
    else
      messages = payload.is_a?(Array) ? payload : [payload]
      return json_response(400, error_response(nil, INVALID_REQUEST, "Invalid request")) if messages.empty?

      context = {base_url: base_url(request), request_base_url: request.base_url}
      responses = messages.filter_map { |message| handle_message(message, context) }

      if responses.empty?
        [202, {}, []]
      else
        json_response(200, payload.is_a?(Array) ? responses : responses.first)
      end
    end

    def handle_message(message, context)
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
      Lookbook.logger.error("[lookbook-mcp] #{e.class}: #{e.message}")
      notification ? nil : error_response(id, INTERNAL_ERROR, e.message)
    end

    def dispatch(method, params, context)
      case method
      when "initialize" then initialize_result(params)
      when "ping" then {}
      when /\Anotifications\// then {}
      when "tools/list" then {tools: McpTools.enabled.map(&:definition)}
      when "tools/call" then call_tool(params, context)
      when "resources/list" then {resources: resources}
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
        serverInfo: {name: "lookbook", title: "#{Lookbook.config.project_name || "Lookbook"} (Lookbook)", version: Lookbook.version},
        instructions: SERVER_INSTRUCTIONS
      }
    end

    def call_tool(params, context)
      tool = McpTools.find(params["name"])
      raise RpcError.new(INVALID_PARAMS, "Unknown tool: #{params["name"]}") unless tool

      arguments = params["arguments"].is_a?(Hash) ? params["arguments"] : {}
      text = tool.handler.call(arguments, context)
      {content: [{type: "text", text: text}], isError: false}
    rescue McpTools::ToolError => e
      {content: [{type: "text", text: e.message}], isError: true}
    end

    def resources
      [
        {uri: "lookbook://manifests/components.json", name: "components.json", title: "Components manifest", mimeType: "application/json"},
        {uri: "lookbook://manifests/docs.json", name: "docs.json", title: "Docs manifest", mimeType: "application/json"}
      ]
    end

    def read_resource(params, context)
      manifest = McpManifest.new(base_url: context[:base_url])
      data = case params["uri"]
      when "lookbook://manifests/components.json" then manifest.components
      when "lookbook://manifests/docs.json" then manifest.docs
      else raise RpcError.new(INVALID_PARAMS, "Unknown resource: #{params["uri"]}")
      end
      {contents: [{uri: params["uri"], mimeType: "application/json", text: JSON.generate(data)}]}
    end

    def info_page(request)
      endpoint = "#{base_url(request)}#{Engine.mount_path}/mcp"
      tools = McpTools.enabled.map do |tool|
        "<li><code>#{ERB::Util.h(tool.name)}</code> <small>(#{tool.toolset})</small> — #{ERB::Util.h(tool.description)}</li>"
      end
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Lookbook MCP server</title>
        <style>body{font-family:system-ui,sans-serif;max-width:720px;margin:2rem auto;padding:0 1rem;line-height:1.5}code{background:#f3f3f3;padding:0 .25em}</style>
        </head>
        <body>
          <h1>Lookbook MCP server</h1>
          <p>Endpoint: <code>#{ERB::Util.h(endpoint)}</code> (Streamable HTTP)</p>
          <p>Add it to Claude Code with: <code>claude mcp add --transport http lookbook #{ERB::Util.h(endpoint)}</code></p>
          <h2>Tools</h2>
          <ul>#{tools.join}</ul>
          <h2>Manifests</h2>
          <ul>
            <li><a href="#{Engine.mount_path}/manifests/components.json">components.json</a></li>
            <li><a href="#{Engine.mount_path}/manifests/docs.json">docs.json</a></li>
          </ul>
        </body>
        </html>
      HTML
    end

    def enabled?
      config.enabled == true
    end

    def origin_allowed?(request)
      origin = request.get_header("HTTP_ORIGIN")
      return true if origin.blank?

      allowed = Array(config.allowed_origins).map { |o| o.to_s.chomp("/") }
      allowed.include?("*") || allowed.include?(origin.chomp("/")) || origin.chomp("/") == request.base_url
    end

    def authorized?(request)
      token = config.token.presence
      return true unless token

      header = request.get_header("HTTP_AUTHORIZATION").to_s
      provided = header.delete_prefix("Bearer ").strip
      provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, token.to_s)
    end

    def base_url(request)
      config.base_url.presence&.chomp("/") || request.base_url
    end

    def config
      Lookbook.config.mcp
    end

    def error_response(id, code, message)
      {jsonrpc: "2.0", id: id, error: {code: code, message: message}}
    end

    def json_response(status, body)
      [status, {"content-type" => "application/json"}, [JSON.generate(body)]]
    end

    def not_found
      [404, {"content-type" => "text/plain"}, ["Not found"]]
    end

    def forbidden(message)
      [403, {"content-type" => "text/plain"}, [message]]
    end

    def unauthorized
      [401, {"content-type" => "text/plain", "www-authenticate" => "Bearer"}, ["Unauthorized"]]
    end

    def method_not_allowed
      [405, {"content-type" => "text/plain", "allow" => "POST"}, ["Method not allowed"]]
    end

    class RpcError < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end
  end
end
