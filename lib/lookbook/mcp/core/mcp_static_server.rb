module Lookbook
  # A read-only MCP server for sharing Lookbook component docs without
  # running the Rails app. Serves the docs toolset from `components.json`
  # and `docs.json` files exported with `rake lookbook:mcp:export`.
  #
  # As a Rack app (Streamable HTTP, e.g. in a `config.ru`):
  #
  #   require "lookbook/mcp/core"
  #   run Lookbook::McpStaticServer.new("lookbook-manifests", token: ENV["LOOKBOOK_MCP_TOKEN"])
  #
  # Over stdio, via the `lookbook-mcp-docs` executable:
  #
  #   lookbook-mcp-docs lookbook-manifests
  class McpStaticServer
    INSTRUCTIONS = "Lookbook component documentation. Use docs-list to find existing components and " \
      "docs-show before using any component argument or slot. Never guess component arguments that " \
      "docs-show does not list."

    attr_reader :directory

    def initialize(directory, token: nil, name: "Lookbook")
      @directory = File.expand_path(directory.to_s)
      @token = token.presence
      @name = name

      [components_path, docs_path].each do |path|
        raise ArgumentError, "Manifest not found: #{path}" unless File.exist?(path)
      end
    end

    def protocol
      @protocol ||= McpProtocol.new(
        tools: -> { McpDocs.tools(->(_context) { manifests }) },
        resources: {
          "lookbook://manifests/components.json" => ->(_context) { read(components_path) },
          "lookbook://manifests/docs.json" => ->(_context) { read(docs_path) }
        },
        server_info: {name: "lookbook-docs", title: "#{@name} (Lookbook docs)", version: defined?(Lookbook::VERSION) ? Lookbook::VERSION : nil}.compact,
        instructions: INSTRUCTIONS
      )
    end

    def run_stdio(input: $stdin, output: $stdout)
      protocol.run_stdio(input: input, output: output)
    end

    # Rack interface
    def call(env)
      method = env["REQUEST_METHOD"]
      return [405, {"content-type" => "text/plain", "allow" => "POST"}, ["Method not allowed"]] unless method == "POST"
      return [401, {"content-type" => "text/plain", "www-authenticate" => "Bearer"}, ["Unauthorized"]] unless authorized?(env)

      status, body = protocol.handle_json(env["rack.input"].read)
      if body
        [status, {"content-type" => "application/json"}, [JSON.generate(body)]]
      else
        [status, {}, []]
      end
    end

    private

    def manifests
      [read(components_path), read(docs_path)]
    end

    def read(path)
      JSON.parse(File.read(path))
    end

    def components_path
      File.join(directory, "components.json")
    end

    def docs_path
      File.join(directory, "docs.json")
    end

    def authorized?(env)
      return true unless @token

      provided = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ").strip
      provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, @token.to_s)
    end
  end
end
