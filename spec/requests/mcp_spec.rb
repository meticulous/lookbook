require "rails_helper"

RSpec.describe "mcp", type: :request do
  let(:mcp_config) { Lookbook.config.mcp }

  around do |example|
    original = mcp_config.to_h.deep_dup
    mcp_config.enabled = true
    example.run
  ensure
    original.each { |key, value| mcp_config[key] = value }
  end

  def rpc(method, params = nil, id: 1, headers: {})
    body = {jsonrpc: "2.0", method: method}
    body[:id] = id unless id.nil?
    body[:params] = params if params
    post "/lookbook/mcp", params: body.to_json, headers: {"CONTENT_TYPE" => "application/json"}.merge(headers)
    JSON.parse(response.body) if response.media_type == "application/json"
  end

  def call_tool(name, arguments = {})
    rpc("tools/call", {name: name, arguments: arguments})["result"]
  end

  def tool_text(name, arguments = {})
    call_tool(name, arguments).dig("content", 0, "text")
  end

  context "when disabled" do
    it "returns a 404" do
      mcp_config.enabled = false
      rpc("ping")

      expect(response.status).to eq 404
    end
  end

  context "protocol" do
    it "responds to initialize" do
      result = rpc("initialize", {protocolVersion: "2025-03-26", capabilities: {}, clientInfo: {name: "test", version: "1"}})["result"]

      expect(result["protocolVersion"]).to eq "2025-03-26"
      expect(result["serverInfo"]["name"]).to eq "lookbook"
      expect(result["capabilities"]).to include("tools", "resources")
    end

    it "falls back to the latest protocol version" do
      result = rpc("initialize", {protocolVersion: "1999-01-01"})["result"]

      expect(result["protocolVersion"]).to eq Lookbook::McpProtocol::PROTOCOL_VERSIONS.first
    end

    it "accepts notifications with a 202" do
      rpc("notifications/initialized", id: nil)

      expect(response.status).to eq 202
      expect(response.body).to be_empty
    end

    it "returns a method not found error for unknown methods" do
      json = rpc("foo/bar")

      expect(json.dig("error", "code")).to eq(-32601)
    end

    it "returns a parse error for invalid JSON" do
      post "/lookbook/mcp", params: "{nope", headers: {"CONTENT_TYPE" => "application/json"}

      expect(response.status).to eq 400
      expect(JSON.parse(response.body).dig("error", "code")).to eq(-32700)
    end

    it "lists tools" do
      names = rpc("tools/list")["result"]["tools"].map { |t| t["name"] }

      expect(names).to contain_exactly(
        "docs-list", "docs-show", "docs-show-story", "get-preview-instructions",
        "previews-show", "previews-find-by-component", "previews-changed", "render-scenario", "previews-check"
      )
    end

    it "respects toolset config" do
      mcp_config.toolsets = {dev: false, docs: true, test: false}
      names = rpc("tools/list")["result"]["tools"].map { |t| t["name"] }

      expect(names).to contain_exactly("docs-list", "docs-show", "docs-show-story")
    end

    it "returns an info page for browsers" do
      get "/lookbook/mcp", headers: {"ACCEPT" => "text/html"}

      expect(response.status).to eq 200
      expect(response.body).to include("docs-list")
    end

    it "rejects GET requests for SSE streams" do
      get "/lookbook/mcp", headers: {"ACCEPT" => "text/event-stream"}

      expect(response.status).to eq 405
    end
  end

  context "security" do
    it "rejects requests from other origins" do
      rpc("ping", headers: {"ORIGIN" => "https://evil.example"})

      expect(response.status).to eq 403
    end

    it "allows same-origin requests" do
      rpc("ping", headers: {"ORIGIN" => "http://www.example.com"})

      expect(response.status).to eq 200
    end

    it "allows configured origins" do
      mcp_config.allowed_origins = ["https://tools.example"]
      rpc("ping", headers: {"ORIGIN" => "https://tools.example"})

      expect(response.status).to eq 200
    end

    it "requires the token when one is configured" do
      mcp_config.token = "secret"

      rpc("ping")
      expect(response.status).to eq 401

      rpc("ping", headers: {"AUTHORIZATION" => "Bearer secret"})
      expect(response.status).to eq 200
    end
  end

  context "docs-list" do
    it "lists visible components and pages" do
      text = tool_text("docs-list")

      expect(text).to include("**Standard** (id: `standard`) renders `StandardComponent`")
      expect(text).to include("(id: `overview`)")
      expect(text).not_to include("(id: `hidden`)")
    end
  end

  context "docs-show" do
    it "prefers the component's own preview when given a component class name" do
      text = tool_text("docs-show", {id: "StandardComponent"})

      expect(text).to include("Preview class: `StandardComponentPreview`")
      expect(text).to include("- `title` (key)")
    end

    it "shows the first scenarios in full and indexes the rest" do
      text = tool_text("docs-show", {id: "standard"})
      scenarios = text.split("## Scenarios").last.split("## Other scenarios").first

      expect(scenarios.scan(/^### /).size).to eq 3
      expect(text).to include("## Other scenarios")
      expect(text).to match(/^- .+ \(id: `standard\/\w+`\)$/)
    end

    it "shows documentation pages" do
      text = tool_text("docs-show", {id: "overview"})

      expect(text).to include("# Welcome")
    end

    it "returns a tool error for unknown ids" do
      result = call_tool("docs-show", {id: "nope"})

      expect(result["isError"]).to be true
      expect(result.dig("content", 0, "text")).to include("docs-list")
    end
  end

  context "params" do
    it "documents scenario params" do
      text = tool_text("docs-show", {id: "params"})

      expect(text).to include("- `select` (string, input: select)")
    end
  end

  context "docs-show-story" do
    it "shows a single scenario" do
      text = tool_text("docs-show-story", {id: "foo/bar/annotated/third_scenario"})

      expect(text).to include("This is a note about the third scenario")
      expect(text).to include("\"third component content\"")
    end
  end

  context "get-preview-instructions" do
    it "returns the default instructions" do
      expect(tool_text("get-preview-instructions")).to include("# Writing Lookbook previews")
    end

    it "returns custom instructions when configured" do
      file = Tempfile.new(["instructions", ".md"])
      file.write("custom instructions")
      file.close
      mcp_config.instructions_path = file.path

      expect(tool_text("get-preview-instructions")).to eq "custom instructions"
    ensure
      file&.unlink
    end
  end

  context "previews-show" do
    it "returns inspect and preview links with params" do
      text = tool_text("previews-show", {ids: ["foo/bar/annotated/another_scenario"], params: {text: "hi there"}})

      expect(text).to include("Inspect: http://www.example.com/lookbook/inspect/foo/bar/annotated/another_scenario?text=hi+there")
      expect(text).to include("Preview: http://www.example.com/lookbook/preview/foo/bar/annotated/another_scenario?text=hi+there")
    end

    it "resolves previews to their default scenario" do
      text = tool_text("previews-show", {ids: ["standard"]})

      expect(text).to include("/lookbook/preview/standard/")
    end

    it "lists ids that were not found" do
      text = tool_text("previews-show", {ids: ["standard", "nope"]})

      expect(text).to include("Not found: `nope`")
    end

    it "is an error when nothing is found" do
      expect(call_tool("previews-show", {ids: ["nope"]})["isError"]).to be true
    end
  end

  context "previews-find-by-component" do
    it "finds previews by component class name" do
      text = tool_text("previews-find-by-component", {components: ["StandardComponent"]})

      expect(text).to include("(id: `standard`, `StandardComponentPreview`)")
      expect(text).to include("(id: `foo/bar/annotated/third_scenario`)")
      expect(text).not_to include("foo/bar/annotated/default")
    end

    it "finds previews by component file path" do
      text = tool_text("previews-find-by-component", {components: ["app/components/standard_component.html.erb"]})

      expect(text).to include("`StandardComponentPreview`")
    end

    it "reports components without previews" do
      text = tool_text("previews-find-by-component", {components: ["BasicComponent"]})

      expect(text).to include("No previews render this component")
    end
  end

  context "render-scenario" do
    it "renders the scenario body" do
      text = tool_text("render-scenario", {id: "foo/bar/annotated/third_scenario"})

      expect(text).to include("```html")
      expect(text).to include("third component content")
      expect(text).not_to include("<body")
    end

    it "renders grouped scenarios as part of their group" do
      text = tool_text("render-scenario", {id: "group/unnamed_group_second"})

      expect(text).to include("first scenario in group")
      expect(text).to include("second scenario in group")
    end

    it "applies params" do
      text = tool_text("render-scenario", {id: "foo/bar/annotated/another_scenario", params: {text: "custom param text"}})

      expect(text).to include("custom param text")
    end

    it "optionally returns the full page" do
      text = tool_text("render-scenario", {id: "foo/bar/annotated/third_scenario", full_page: true})

      expect(text).to include("<body")
    end

    it "truncates long output" do
      text = tool_text("render-scenario", {id: "foo/bar/annotated/third_scenario", max_length: 10})

      expect(text).to include("Output truncated to 10 of")
    end

    it "returns the error raised while rendering" do
      allow_any_instance_of(StandardComponent).to receive(:before_render).and_raise(ArgumentError, "kaboom")
      result = call_tool("render-scenario", {id: "foo/bar/annotated/third_scenario"})

      expect(result["isError"]).to be true
      expect(result.dig("content", 0, "text")).to include("ArgumentError: kaboom")
    end

    it "is an error for unknown ids" do
      expect(call_tool("render-scenario", {id: "nope"})["isError"]).to be true
    end
  end

  context "previews-check" do
    it "checks every visible scenario by default" do
      text = tool_text("previews-check")

      expect(text).to match(/\AChecked \d+ scenarios: \d+ passed, 0 failed/)
    end

    it "reports failures with the error" do
      allow_any_instance_of(StandardComponent).to receive(:before_render).and_raise(ArgumentError, "kaboom")
      text = tool_text("previews-check", {components: ["StandardComponent"]})

      expect(text).to include("0 passed")
      expect(text).to include("### Standard / Default (id: `standard/default`)")
      expect(text).to include("ArgumentError: kaboom")
    end

    it "checks specific scenarios" do
      text = tool_text("previews-check", {ids: ["standard/default", "nope"]})

      expect(text).to start_with("Checked 1 scenario: 1 passed, 0 failed.")
      expect(text).to include("Not found: `nope`")
    end

    it "checks scenarios affected by git changes" do
      allow_any_instance_of(Lookbook::McpGitChanges).to receive(:files).and_return(["app/components/inline_component.rb"])
      text = tool_text("previews-check", {changed: true})

      expect(text).to match(/\AChecked \d+ scenarios?: /)
      expect(text).not_to include("0 passed")
    end
  end

  context "previews-changed" do
    let(:changed_files) { [] }

    before do
      allow_any_instance_of(Lookbook::McpGitChanges).to receive(:files).and_return(changed_files)
    end

    context "with a changed preview file" do
      let(:changed_files) { ["test/components/previews/inline_component_preview.rb"] }

      it "lists the preview and its scenarios" do
        text = tool_text("previews-changed")

        expect(text).to include("`InlineComponentPreview`) — preview file changed")
        expect(text).to include("(id: `inline/default`)")
      end
    end

    context "with a changed component" do
      let(:changed_files) { ["app/components/standard_component.html.erb", "app/components/basic_component.rb", "README.md"] }

      it "lists previews that render it and components without previews" do
        text = tool_text("previews-changed")

        expect(text).to include("`StandardComponentPreview`) — renders `app/components/standard_component.html.erb`")
        expect(text).to include("## Changed components without previews\n\n- `app/components/basic_component.rb`")
        expect(text).not_to include("README.md`")
      end
    end

    context "without changes" do
      it "says nothing is affected" do
        expect(tool_text("previews-changed")).to include("No previews are affected")
      end
    end

    it "rejects option-like refs" do
      allow_any_instance_of(Lookbook::McpGitChanges).to receive(:files).and_call_original
      result = call_tool("previews-changed", {base: "--output=/tmp/x"})

      expect(result["isError"]).to be true
      expect(result.dig("content", 0, "text")).to include("Invalid git ref")
    end
  end

  context "custom tools" do
    after { Lookbook.remove_mcp_tool("echo") }

    it "can be added and called" do
      Lookbook.add_mcp_tool("echo", description: "Echoes text", input_schema: {type: "object", properties: {text: {type: "string"}}}) do |args, context|
        "#{args["text"]} from #{context[:base_url]}"
      end

      expect(rpc("tools/list")["result"]["tools"].map { |t| t["name"] }).to include("echo")
      expect(tool_text("echo", {text: "hello"})).to eq "hello from http://www.example.com"
    end

    it "returns raised errors as tool errors" do
      Lookbook.add_mcp_tool("echo", description: "Fails") { |_args, _context| raise "nope" }
      result = call_tool("echo")

      expect(result["isError"]).to be true
      expect(result.dig("content", 0, "text")).to eq "RuntimeError: nope"
    end

    it "can be disabled with its toolset" do
      Lookbook.add_mcp_tool("echo", description: "Echoes", toolset: :extras) { |_args, _context| "hi" }
      mcp_config.toolsets = {dev: true, docs: true, test: true, extras: false}

      expect(rpc("tools/list")["result"]["tools"].map { |t| t["name"] }).not_to include("echo")
    end
  end

  context "resources" do
    it "reads the components manifest" do
      result = rpc("resources/read", {uri: "lookbook://manifests/components.json"})["result"]
      data = JSON.parse(result.dig("contents", 0, "text"))

      expect(data["components"]).to include("standard")
    end
  end

  context "manifest endpoints" do
    it "serves the components manifest" do
      get "/lookbook/manifests/components.json"
      data = JSON.parse(response.body)
      standard = data["components"]["standard"]

      expect(standard["preview_class"]).to eq "StandardComponentPreview"
      expect(standard["components"].first["name"]).to eq "StandardComponent"
      expect(standard["scenarios"].first["preview_url"]).to start_with "http://www.example.com/lookbook/preview/"
    end

    it "serves the docs manifest" do
      get "/lookbook/manifests/docs.json"

      expect(JSON.parse(response.body)["docs"]).to include("overview")
    end

    it "uses the configured base URL" do
      mcp_config.base_url = "https://lookbook.test/"
      get "/lookbook/manifests/components.json"

      expect(response.body).to include("https://lookbook.test/lookbook/inspect/")
    end

    it "is not available when disabled" do
      mcp_config.enabled = false
      get "/lookbook/manifests/components.json"

      expect(response.status).to eq 404
    end
  end
end
