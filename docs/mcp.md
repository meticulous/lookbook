# Lookbook MCP server

An MCP server for Lookbook, modelled on Storybook's `@storybook/addon-mcp`
(https://storybook.js.org/docs/ai/mcp/overview). It gives AI agents structured
access to the components, previews and docs pages in a Lookbook instance.

Lookbook's public extension points (panels, inputs, tags, hooks) only reach the UI
and preview annotations, so this is built into the engine (`lib/lookbook/mcp/`).

## Setup

The server is enabled by default in development and disabled everywhere else.

```ruby
# config/environments/development.rb
config.lookbook.mcp.enabled = true               # default in development
config.lookbook.mcp.toolsets = {dev: true, docs: true, test: true}
config.lookbook.mcp.instructions_path = "docs/lookbook_preview_instructions.md" # optional override
config.lookbook.mcp.base_url = "http://localhost:3000" # optional, defaults to the request's host
config.lookbook.mcp.allowed_origins = []          # extra browser origins allowed to call the server
config.lookbook.mcp.token = ENV["LOOKBOOK_MCP_TOKEN"] # optional bearer token
config.lookbook.mcp.apps = true                  # MCP Apps inline preview view for previews-show
```

With Lookbook mounted at `/lookbook`, the endpoint is `http://localhost:3000/lookbook/mcp`
(Streamable HTTP transport). Opening it in a browser shows the available tools.

```sh
claude mcp add --transport http lookbook http://localhost:3000/lookbook/mcp
```

### stdio

For agents that launch MCP servers as local commands instead of connecting over HTTP:

```sh
claude mcp add lookbook -- bin/rails lookbook:mcp:stdio
```

Links in tool output use `mcp.base_url`, `LOOKBOOK_BASE_URL`, or `http://localhost:3000`.
The app is booted in-process, so `render-scenario` and `previews-check` work without a running server.

### Sharing docs without running the app

Like Storybook's `@storybook/mcp` self-hosting, the docs toolset can be served from exported manifests:

```sh
LOOKBOOK_BASE_URL=https://lookbook.example.com bin/rails lookbook:mcp:export[lookbook-manifests]
```

Then serve them without Rails, over stdio:

```sh
claude mcp add lookbook-docs -- bundle exec lookbook-mcp-docs lookbook-manifests
```

or over HTTP from any Rack server (`config.ru`):

```ruby
require "lookbook/mcp/core"
run Lookbook::McpStaticServer.new("lookbook-manifests", token: ENV["LOOKBOOK_MCP_TOKEN"])
```

### Accessibility checks

`previews-check` with `a11y: true` runs [axe-core](https://github.com/dequelabs/axe-core) against
each scenario in headless Chrome. Add the optional dependencies to the app's Gemfile:

```ruby
group :development do
  gem "ferrum"       # drives headless Chrome/Chromium
  gem "axe-core-api" # provides axe.min.js (or install the `axe-core` npm package)
end
```

The browser's requests to the app are answered in-process by the Rails app, so no running
server is needed and results use the app's real stylesheets. Requests to other hosts are blocked.

```ruby
config.lookbook.mcp.a11y.browser_path = "/path/to/chrome" # or BROWSER_PATH; auto-detected otherwise
config.lookbook.mcp.a11y.axe_path = "vendor/axe.min.js"    # optional, relative to the app root
config.lookbook.mcp.a11y.timeout = 30                      # seconds
config.lookbook.mcp.a11y.options = {                       # passed to axe.run
  runOnly: {type: "tag", values: ["wcag2a", "wcag2aa"]}
}
```

By default the page-structure rules `region`, `landmark-one-main` and `page-has-heading-one`
are disabled, because previews render components in isolation. Setting `a11y.options` replaces
those defaults.

### Inline previews (MCP Apps)

`previews-show` declares an [MCP Apps](https://github.com/modelcontextprotocol/ext-apps) view
(`ui://lookbook/previews`, SEP-1865). Hosts that support MCP Apps render the returned scenarios
inline in iframes, with an "Open in Lookbook" button; other hosts use the text result. The view's
CSP allows framing only the Lookbook origin (`base_url`). Hosts on HTTPS may refuse to frame an
`http://localhost` app, in which case the links still work.

### Custom tools

```ruby
# config/initializers/lookbook.rb
Lookbook.add_mcp_tool("design-tokens",
  description: "Returns the design tokens available to components",
  input_schema: {type: "object", properties: {group: {type: "string"}}}
) do |args, context|
  DesignTokens.to_markdown(group: args["group"]) # must return a String
end
```

Raise `Lookbook::McpToolError` to return an error message to the agent. Custom tools belong
to the `custom` toolset unless `toolset:` is given, and can be switched off via `mcp.toolsets`.

Suggested `AGENTS.md` / `CLAUDE.md` snippet:

```md
When working on UI components, use the `lookbook` MCP tools before writing any view code.

- Query `docs-list` to find existing components.
- Query `docs-show` for a component before using it. Only use constructor arguments and slots it documents.
- Call `get-preview-instructions` before creating or updating previews.
- After changing components, run `previews-check` with `changed: true` (and `a11y: true`), fix any failures and re-run.
- Share `previews-show` links so the user can review the result.
```

## Tools

| Toolset | Tool | Storybook equivalent | Status |
|---|---|---|---|
| docs | `docs-list` | `docs-list` | Done |
| docs | `docs-show` | `docs-show` | Done |
| docs | `docs-show-story` | `docs-show-story` | Done |
| dev | `get-preview-instructions` | `get-storybook-story-instructions` | Done |
| dev | `previews-show` | `stories-preview` | Done (links, plus MCP Apps inline view) |
| dev | `previews-find-by-component` | `stories-find-by-component` | Done |
| dev | `render-scenario` | none | Done |
| dev | `previews-changed` | `stories-changed` | Done |
| test | `previews-check` | `test-run` | Done (render errors, empty output, optional axe checks) |

Resources: `lookbook://manifests/components.json`, `lookbook://manifests/docs.json`, and the
MCP Apps view `ui://lookbook/previews`.

## Manifests

Equivalent to Storybook's `/manifests/components.json` and `/manifests/docs.json`:

- `<mount>/manifests/components.json`: one entry per visible preview, with the components
  it renders (class, source path, template path, class comment, `initialize` arguments with
  `@param` docs, ViewComponent slots) and its scenarios (notes, `@param` definitions,
  source snippet, inspect and preview URLs).
- `<mount>/manifests/docs.json`: Lookbook pages with their raw source.

## Implementation phases

1. **Done:** manifests, docs toolset, preview instructions, HTTP endpoint and info page, config, origin and token checks.
2. **Done:** `previews-show`, `previews-find-by-component`, and `render-scenario` (rendered HTML with params).
3. **Done:** `previews-check`, `previews-changed`, `lookbook:mcp:export` plus the Rails-free
   `lookbook-mcp-docs` / `McpStaticServer` docs server, `Lookbook.add_mcp_tool`, `lookbook:mcp:stdio`.
4. **Done:** axe accessibility checks via Ferrum and headless Chrome; MCP Apps inline previews.

## Notes

- The transport is stateless: every `POST` returns a single JSON response, `GET` without
  `text/html` returns 405 (no SSE stream), and no `Mcp-Session-Id` is issued.
- Manifests are built per request from the in-memory preview and page collections,
  so they always reflect the reloaded state. Cache if this becomes slow on large libraries.
- `render-scenario` makes an internal request to the standalone preview route, so layouts,
  param casting and display options match the UI. Render errors come back as the exception
  class, message and cleaned backtrace instead of Lookbook's HTML error page.
- `previews-find-by-component` matches component class names, Ruby file paths and template
  or partial paths (relative to the app root).
- Scenarios inside a `@!group` can only be rendered as part of their group, so their preview
  URLs, `render-scenario` and `previews-check` all use the group.
- `previews-changed` uses `git diff --relative <base>` plus untracked files, so paths are relative
  to the app root. Changed files under component paths that no preview renders are listed separately.
- The protocol, docs toolset and static server live in `lib/lookbook/mcp/core` and only need
  `json` and ActiveSupport, so they can run without Rails.
- Accessibility checks run while the MCP request waits; the browser's requests are served on
  Ferrum's thread, inside `permit_concurrent_loads` so code loading isn't blocked.
- Component descriptions come from the comment block above the class definition and
  argument descriptions from `@param` lines above `def initialize`.
