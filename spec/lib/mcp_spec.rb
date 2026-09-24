require "rails_helper"
require "open3"
require "stringio"
require "tmpdir"

RSpec.describe "Lookbook MCP" do
  def rpc_line(method, params = nil, id: 1)
    JSON.generate({jsonrpc: "2.0", id: id, method: method, params: params}.compact)
  end

  let(:export_dir) { Dir.mktmpdir("lookbook-manifests") }

  after { FileUtils.remove_entry(export_dir) }

  describe Lookbook::McpManifest do
    it "exports the components and docs manifests" do
      paths = described_class.export(export_dir, base_url: "https://lookbook.test")

      expect(paths.map { |p| File.basename(p) }).to eq ["components.json", "docs.json"]

      components = JSON.parse(File.read(File.join(export_dir, "components.json")))
      expect(components.dig("components", "standard", "inspect_url")).to start_with "https://lookbook.test/lookbook/inspect/"
      expect(JSON.parse(File.read(File.join(export_dir, "docs.json")))["docs"]).to include("overview")
    end
  end

  describe Lookbook::McpProtocol do
    it "runs over stdio" do
      input = StringIO.new([
        rpc_line("initialize", {protocolVersion: "2025-06-18"}),
        JSON.generate({jsonrpc: "2.0", method: "notifications/initialized"}),
        "",
        rpc_line("tools/call", {name: "docs-show", arguments: {id: "StandardComponent"}}, id: 2)
      ].join("\n"))
      output = StringIO.new

      Lookbook::McpServer.protocol.run_stdio(input: input, output: output, context: {base_url: "http://localhost:3000"})
      responses = output.string.lines.map { |line| JSON.parse(line) }

      expect(responses.map { |r| r["id"] }).to eq [1, 2]
      expect(responses.first.dig("result", "serverInfo", "name")).to eq "lookbook"
      expect(responses.last.dig("result", "content", 0, "text")).to include("Preview class: `StandardComponentPreview`")
    end
  end

  describe Lookbook::McpStaticServer do
    before { Lookbook::McpManifest.export(export_dir, base_url: "https://lookbook.test") }

    let(:server) { described_class.new(export_dir, token: token) }
    let(:token) { nil }

    def post_rpc(body, headers = {})
      env = Rack::MockRequest.env_for("/", {method: "POST", input: body}.merge(headers))
      status, headers, response = server.call(env)
      [status, (headers["content-type"] == "application/json") ? JSON.parse(response.first) : nil]
    end

    it "requires the manifest files" do
      expect { described_class.new(File.join(export_dir, "missing")) }.to raise_error(ArgumentError, /Manifest not found/)
    end

    it "serves the docs toolset only" do
      _status, json = post_rpc(rpc_line("tools/list"))

      expect(json["result"]["tools"].map { |t| t["name"] }).to eq ["docs-list", "docs-show", "docs-show-story"]
    end

    it "serves docs from the exported manifests" do
      _status, json = post_rpc(rpc_line("tools/call", {name: "docs-show", arguments: {id: "StandardComponent"}}))
      text = json.dig("result", "content", 0, "text")

      expect(text).to include("Preview class: `StandardComponentPreview`")
      expect(text).to include("Inspect: https://lookbook.test/lookbook/inspect/standard")
    end

    it "serves scenarios and pages" do
      _status, json = post_rpc(rpc_line("tools/call", {name: "docs-show-story", arguments: {id: "foo/bar/annotated/third_scenario"}}))
      expect(json.dig("result", "content", 0, "text")).to include("This is a note about the third scenario")

      _status, json = post_rpc(rpc_line("tools/call", {name: "docs-show", arguments: {id: "overview"}}))
      expect(json.dig("result", "content", 0, "text")).to include("# Welcome")
    end

    it "rejects non-POST requests" do
      status, _headers, _body = server.call(Rack::MockRequest.env_for("/"))

      expect(status).to eq 405
    end

    context "with a token" do
      let(:token) { "secret" }

      it "requires it" do
        expect(post_rpc(rpc_line("ping")).first).to eq 401
        expect(post_rpc(rpc_line("ping"), "HTTP_AUTHORIZATION" => "Bearer secret").first).to eq 200
      end
    end
  end

  describe "MCP Apps previews view", :browser do
    # A minimal MCP Apps host: frames the view, answers ui/initialize,
    # waits for ui/notifications/initialized, then sends the tool result.
    let(:host_page) do
      <<~HTML
        <!DOCTYPE html>
        <html><body>
          <iframe id="view"></iframe>
          <script>
            window.__log = [];
            const frame = document.getElementById("view");
            const toolResult = #{JSON.generate(tool_result)};
            window.addEventListener("message", (event) => {
              const message = event.data;
              window.__log.push(message.method || ("response:" + message.id));
              if (message.method === "ui/initialize") {
                window.__initParams = message.params;
                frame.contentWindow.postMessage({jsonrpc: "2.0", id: message.id, result: {
                  protocolVersion: "2026-01-26", hostInfo: {name: "test-host", version: "1"},
                  hostCapabilities: {}, hostContext: {theme: "dark", styles: {variables: {"--color-text-primary": "rgb(1, 2, 3)"}}}
                }}, "*");
              }
              if (message.method === "ui/notifications/initialized") {
                frame.contentWindow.postMessage({jsonrpc: "2.0", method: "ui/notifications/tool-input", params: {arguments: {}}}, "*");
                frame.contentWindow.postMessage({jsonrpc: "2.0", method: "ui/notifications/tool-result", params: toolResult}, "*");
              }
              if (message.method === "ui/open-link") {
                window.__openedLink = message.params.url;
                frame.contentWindow.postMessage({jsonrpc: "2.0", id: message.id, result: {}}, "*");
              }
            });
            frame.srcdoc = #{JSON.generate(File.read(Lookbook::McpApps::PREVIEWS_VIEW_PATH, encoding: "UTF-8")).gsub("</", "<\\/")};
          </script>
        </body></html>
      HTML
    end

    let(:tool_result) do
      {
        content: [{type: "text", text: "..."}],
        structuredContent: {
          previews: [
            {title: "Button / Default", lookup_path: "button/default", preview_url: "http://localhost:3000/lookbook/preview/button/default", inspect_url: "http://localhost:3000/lookbook/inspect/button/default"},
            {title: "Bad <script>", lookup_path: "bad", preview_url: "javascript:alert(1)", inspect_url: "javascript:alert(1)"}
          ],
          missing: ["nope"]
        }
      }
    end

    it "completes the handshake and renders the previews" do
      require "ferrum"
      browser = Ferrum::Browser.new(headless: true, timeout: 15, browser_path: ENV["BROWSER_PATH"].presence,
        browser_options: Process.uid.zero? ? {"no-sandbox" => nil} : {})
      page = browser.create_page
      page.network.intercept
      page.on(:request) { |request| request.abort }
      page.content = host_page

      rendered = nil
      50.times do
        rendered = page.evaluate(<<~JS)
          (() => {
            const doc = document.getElementById("view").contentDocument;
            const frames = doc ? Array.from(doc.querySelectorAll("iframe")) : [];
            if (frames.length === 0) return null;
            doc.querySelector("button").click();
            return {
              titles: Array.from(doc.querySelectorAll("h2")).map((h) => h.textContent),
              frames: frames.map((f) => f.getAttribute("src")),
              missing: doc.querySelector(".missing") && doc.querySelector(".missing").textContent,
              textColor: getComputedStyle(doc.body).color
            };
          })()
        JS
        break if rendered
        sleep 0.1
      end
      sleep 0.2

      expect(page.evaluate("window.__initParams")).to include(
        "protocolVersion" => "2026-01-26",
        "appInfo" => {"name" => "lookbook-previews", "version" => "1.0.0"}
      )
      expect(page.evaluate("window.__log")).to include("ui/initialize", "ui/notifications/initialized", "ui/notifications/size-changed")
      expect(rendered["titles"]).to eq ["Button / Default"]
      expect(rendered["frames"]).to eq ["http://localhost:3000/lookbook/preview/button/default"]
      expect(rendered["missing"]).to eq "Not found: nope"
      expect(rendered["textColor"]).to eq "rgb(1, 2, 3)"
      expect(page.evaluate("window.__openedLink")).to eq "http://localhost:3000/lookbook/inspect/button/default"
    ensure
      browser&.quit
    end
  end

  describe "lookbook-mcp-docs executable" do
    before { Lookbook::McpManifest.export(export_dir) }

    it "serves docs over stdio without loading Rails" do
      exe = Lookbook::Engine.root.join("exe/lookbook-mcp-docs").to_s
      input = [
        rpc_line("initialize", {protocolVersion: "2025-06-18"}),
        rpc_line("tools/call", {name: "docs-list"}, id: 2)
      ].join("\n")

      output, status = Open3.capture2(RbConfig.ruby, exe, export_dir, stdin_data: input)
      responses = output.lines.map { |line| JSON.parse(line) }

      expect(status).to be_success
      expect(responses.first.dig("result", "serverInfo", "name")).to eq "lookbook-docs"
      expect(responses.last.dig("result", "content", 0, "text")).to include("**Standard** (id: `standard`)")
    end

    it "exits with an error for a missing directory" do
      exe = Lookbook::Engine.root.join("exe/lookbook-mcp-docs").to_s
      _output, error, status = Open3.capture3(RbConfig.ruby, exe, File.join(export_dir, "missing"))

      expect(status).not_to be_success
      expect(error).to include("Manifest not found")
    end
  end
end
