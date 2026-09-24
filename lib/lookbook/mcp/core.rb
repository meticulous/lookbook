# Rails-independent parts of the Lookbook MCP server: the JSON-RPC protocol,
# the docs toolset (which works from manifest data alone) and the static
# docs server. Can be required on its own, without loading Rails or Lookbook:
#
#   require "lookbook/mcp/core"
#   run Lookbook::McpStaticServer.new("path/to/manifests")

require "json"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/string/filters"
require "active_support/security_utils"

require_relative "core/mcp_tool"
require_relative "core/mcp_protocol"
require_relative "core/mcp_docs"
require_relative "core/mcp_static_server"
