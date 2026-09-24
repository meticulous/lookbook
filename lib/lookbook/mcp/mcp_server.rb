module Lookbook
  # Rack endpoint implementing the MCP Streamable HTTP transport
  # (stateless, JSON responses only) for the live Lookbook instance.
  #
  # Mounted at `<lookbook mount path>/mcp`. Also serves the
  # `/manifests/components.json` and `/manifests/docs.json` endpoints.
  #
  # @api private
  class McpServer
    INSTRUCTIONS = "Lookbook component library for this Rails app. Use docs-list to find existing " \
      "components, docs-show before using any component argument or slot, and get-preview-instructions " \
      "before writing previews. Check your work with render-scenario or previews-check and share links from " \
      "previews-show. Never guess component arguments that docs-show does not list."

    def self.manifest_endpoint(name)
      ->(env) { new.manifest_response(env, name) }
    end

    # The shared protocol handler, also used by the stdio server.
    def self.protocol
      McpProtocol.new(
        tools: -> { McpTools.enabled },
        resources: -> {
          [
            McpResource.json("lookbook://manifests/components.json") { |context| McpManifest.new(base_url: context[:base_url]).components },
            McpResource.json("lookbook://manifests/docs.json") { |context| McpManifest.new(base_url: context[:base_url]).docs },
            (McpApps.previews_view if McpApps.enabled?)
          ].compact
        },
        server_info: {
          name: "lookbook",
          title: "#{Lookbook.config.project_name || "Lookbook"} (Lookbook)",
          version: Lookbook.version
        },
        instructions: INSTRUCTIONS,
        logger: Lookbook.logger
      )
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
      context = {base_url: base_url(request), request_base_url: request.base_url}
      status, body = self.class.protocol.handle_json(request.body.read, context)
      body ? json_response(status, body) : [status, {}, []]
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
  end
end
