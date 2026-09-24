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
