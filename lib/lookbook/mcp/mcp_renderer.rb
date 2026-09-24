module Lookbook
  # Renders a preview scenario for the MCP `render-scenario` tool by making an
  # internal request to Lookbook's standalone preview route, so layouts,
  # param casting and display options behave exactly as they do in the UI.
  #
  # @api private
  class McpRenderer
    ENV_KEY = "lookbook.mcp_render"
    Result = Struct.new(:status, :html, :error, keyword_init: true) do
      def success?
        status.to_i.between?(200, 299)
      end
    end

    attr_reader :base_url

    def initialize(base_url:)
      @base_url = base_url.to_s.chomp("/")
    end

    def call(scenario, params: {})
      url = "#{base_url}#{scenario.preview_path}"
      query = params.to_h.to_query
      url += "?#{query}" if query.present?

      env = Rack::MockRequest.env_for(url, "HTTP_ACCEPT" => "text/html", ENV_KEY => true)
      status, headers, body = Rails.application.call(env)
      content = read_body(body)

      if status.to_i.between?(300, 399)
        Result.new(status: status, error: "Preview redirected to #{headers["location"] || headers["Location"]}")
      elsif status.to_i.between?(200, 299)
        Result.new(status: status, html: content)
      else
        Result.new(status: status, error: content)
      end
    end

    # Extracts the contents of the `<body>` element, if present.
    def self.body_content(html)
      match = html.to_s.match(/<body[^>]*>(.*)<\/body>/mi)
      match ? match[1].strip : html.to_s.strip
    end

    private

    def read_body(body)
      parts = []
      body.each { |part| parts << part }
      parts.join
    ensure
      body.close if body.respond_to?(:close)
    end
  end
end
