module Lookbook
  # MCP Apps (SEP-1865, `io.modelcontextprotocol/ui`) support: an inline
  # view that hosts supporting MCP Apps render for `previews-show` results.
  # Hosts without MCP Apps support ignore the metadata and use the text result.
  #
  # @api private
  class McpApps
    PREVIEWS_VIEW_URI = "ui://lookbook/previews"
    MIME_TYPE = "text/html;profile=mcp-app"
    PREVIEWS_VIEW_PATH = File.expand_path("previews_view.html", __dir__)

    class << self
      def enabled?
        Lookbook.config.mcp.apps != false
      end

      # `_meta` for tools whose results the previews view renders.
      def previews_tool_meta
        ->(_context) { {ui: {resourceUri: PREVIEWS_VIEW_URI}} if enabled? }
      end

      def previews_view
        McpResource.new(
          uri: PREVIEWS_VIEW_URI,
          name: "Lookbook previews",
          mime_type: MIME_TYPE,
          loader: ->(_context) { File.read(PREVIEWS_VIEW_PATH, encoding: "UTF-8") },
          meta: ->(context) {
            origin = origin_for(context[:base_url])
            {ui: {csp: {frameDomains: [origin].compact}, prefersBorder: true}}
          }
        )
      end

      private

      def origin_for(url)
        uri = URI.parse(url.to_s)
        return unless uri.is_a?(URI::HTTP) && uri.host

        default_port = (uri.scheme == "https") ? 443 : 80
        port = (uri.port == default_port) ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host}#{port}"
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
