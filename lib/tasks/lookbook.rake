namespace :lookbook do
  namespace :mcp do
    desc "Export the Lookbook MCP manifests (components.json, docs.json) to DIR (default: lookbook-manifests)"
    task :export, [:dir] => :environment do |_task, args|
      dir = Pathname(args[:dir].presence || ENV["DIR"].presence || "lookbook-manifests").expand_path(Rails.root)
      base_url = ENV["LOOKBOOK_BASE_URL"].presence || Lookbook.config.mcp.base_url

      paths = Lookbook::McpManifest.export(dir, base_url: base_url)
      paths.each { |path| puts "Wrote #{path}" }
    end

    protocol_output = nil

    # Runs before the app boots so nothing written to stdout while loading
    # (log output, YARD warnings, app code) can corrupt protocol messages:
    # file descriptor 1 is pointed at stderr and the original stdout is
    # kept for the protocol alone.
    task :redirect_stdout do
      protocol_output = $stdout.dup
      $stdout.reopen($stderr)
    end

    desc "Run the Lookbook MCP server over stdio (for agents that launch MCP servers as local commands)"
    task stdio: [:redirect_stdout, :environment] do
      base_url = ENV["LOOKBOOK_BASE_URL"].presence || Lookbook.config.mcp.base_url.presence || "http://localhost:3000"
      Lookbook::McpServer.protocol.run_stdio(
        input: $stdin,
        output: protocol_output,
        context: {base_url: base_url.chomp("/")}
      )
    end
  end
end
