module Lookbook
  # Runs axe-core accessibility checks against preview scenarios in headless
  # Chrome (via the optional `ferrum` gem).
  #
  # Every request the browser makes to the app is intercepted and answered
  # in-process by the Rails app, so no running web server is needed and
  # results include the app's real stylesheets (for colour contrast etc).
  #
  # @api private
  class McpA11yChecker
    AXE_GEM_PATH = "node_modules/axe-core/axe.min.js"
    MAX_NODES = 3

    Violation = Struct.new(:id, :impact, :help, :help_url, :nodes, keyword_init: true)

    attr_reader :base_url

    def initialize(base_url:)
      @base_url = base_url.to_s.chomp("/")
    end

    # @return [Array<Violation>] Violations for the scenario
    def call(scenario)
      # The browser's requests are answered by the Rails app on Ferrum's
      # thread while this one waits, so let other threads load code meanwhile.
      violations = ActiveSupport::Dependencies.interlock.permit_concurrent_loads { run_axe(scenario) }

      raise Lookbook::Error, "axe failed: #{violations["error"]}" if violations.is_a?(Hash) && violations["error"]

      Array(violations).map { |violation| build_violation(violation) }
    end

    def close
      @browser&.quit
      @browser = nil
    end

    def self.available?
      require "ferrum"
      true
    rescue LoadError
      false
    end

    def self.axe_path
      configured = Lookbook.config.mcp.a11y.to_h[:axe_path].presence
      candidates = [
        (Rails.root.join(configured).to_s if configured),
        Rails.root.join("node_modules/axe-core/axe.min.js").to_s,
        (File.join(Gem.loaded_specs["axe-core-api"].full_gem_path, AXE_GEM_PATH) if Gem.loaded_specs["axe-core-api"])
      ]
      candidates.compact.find { |path| File.exist?(path) }
    end

    private

    def run_axe(scenario)
      page = browser.create_page
      page.network.intercept
      page.on(:request) { |request| handle_request(request) }

      page.go_to("#{base_url}#{scenario.preview_path}")
      page.add_script_tag(content: axe_source)

      # Ferrum passes the callback as the last argument.
      page.evaluate_async(<<~JS, timeout, axe_options)
        const options = arguments[0];
        const done = arguments[arguments.length - 1];
        axe.run(document, Object.assign({resultTypes: ["violations"]}, options))
          .then((results) => done(results.violations))
          .catch((error) => done({error: String(error)}));
      JS
    ensure
      page&.close
    end

    def browser
      @browser ||= begin
        require "ferrum"
        Ferrum::Browser.new(
          headless: true,
          timeout: timeout,
          process_timeout: timeout,
          window_size: [1280, 800],
          browser_path: config[:browser_path].presence || ENV["BROWSER_PATH"].presence,
          # Chrome refuses to start sandboxed as root (e.g. in containers).
          browser_options: Process.uid.zero? ? {"no-sandbox" => nil} : {}
        )
      end
    end

    # Serves requests for the app from the Rails app itself;
    # blocks everything else so results are deterministic.
    def handle_request(request)
      return request.abort unless request.url.start_with?("#{base_url}/")

      env = Rack::MockRequest.env_for(request.url, "REQUEST_METHOD" => request.method.to_s.upcase)
      status, headers, body = Rails.application.call(env)
      content = +""
      body.each { |part| content << part.to_s }
      body.close if body.respond_to?(:close)

      response_headers = headers.to_h.transform_keys(&:to_s).reject { |key, _| key.casecmp?("content-length") }
      request.respond(responseCode: status.to_i, responseHeaders: response_headers, body: content.b)
    rescue => e
      Lookbook.logger.error("[lookbook-mcp] a11y request failed for #{request.url}: #{e.message}")
      request.abort
    end

    def build_violation(data)
      Violation.new(
        id: data["id"],
        impact: data["impact"],
        help: data["help"],
        help_url: data["helpUrl"],
        nodes: Array(data["nodes"]).first(MAX_NODES).map do |node|
          {target: Array(node["target"]).join(" "), summary: node["failureSummary"].to_s.strip}
        end
      )
    end

    def axe_source
      @axe_source ||= begin
        path = self.class.axe_path
        unless path
          raise McpToolError, "axe-core not found. Add `gem \"axe-core-api\"` to your Gemfile's development group, " \
            "install the `axe-core` npm package, or set `config.lookbook.mcp.a11y.axe_path`."
        end
        File.read(path, encoding: "UTF-8")
      end
    end

    def axe_options
      config[:options].to_h.deep_stringify_keys
    end

    def timeout
      (config[:timeout].presence || 30).to_i
    end

    def config
      Lookbook.config.mcp.a11y.to_h.symbolize_keys
    end
  end
end
