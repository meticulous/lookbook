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
config.lookbook.mcp.toolsets = {dev: true, docs: true}
config.lookbook.mcp.instructions_path = "docs/lookbook_preview_instructions.md" # optional override
config.lookbook.mcp.base_url = "http://localhost:3000" # optional, defaults to the request's host
config.lookbook.mcp.allowed_origins = []          # extra browser origins allowed to call the server
config.lookbook.mcp.token = ENV["LOOKBOOK_MCP_TOKEN"] # optional bearer token
```

With Lookbook mounted at `/lookbook`, the endpoint is `http://localhost:3000/lookbook/mcp`
(Streamable HTTP transport). Opening it in a browser shows the available tools.

```sh
claude mcp add --transport http lookbook http://localhost:3000/lookbook/mcp
```

Suggested `AGENTS.md` / `CLAUDE.md` snippet:

```md
When working on UI components, use the `lookbook` MCP tools before writing any view code.

- Query `docs-list` to find existing components.
- Query `docs-show` for a component before using it. Only use constructor arguments and slots it documents.
- Call `get-preview-instructions` before creating or updating previews.
```

## Tools

| Toolset | Tool | Storybook equivalent | Status |
|---|---|---|---|
| docs | `docs-list` | `docs-list` | Done |
| docs | `docs-show` | `docs-show` | Done |
| docs | `docs-show-story` | `docs-show-story` | Done |
| dev | `get-preview-instructions` | `get-storybook-story-instructions` | Done |
| dev | `previews-show` | `stories-preview` | Phase 2 |
| dev | `previews-find-by-component` | `stories-find-by-component` | Phase 2 |
| dev | `render-scenario` | none | Phase 2 |
| dev | `previews-changed` | `stories-changed` | Phase 3 |
| test | `previews-check` | `test-run` | Phase 3 |

Resources: `lookbook://manifests/components.json`, `lookbook://manifests/docs.json`.

## Manifests

Equivalent to Storybook's `/manifests/components.json` and `/manifests/docs.json`:

- `<mount>/manifests/components.json`: one entry per visible preview, with the components
  it renders (class, source path, template path, class comment, `initialize` arguments with
  `@param` docs, ViewComponent slots) and its scenarios (notes, `@param` definitions,
  source snippet, inspect and preview URLs).
- `<mount>/manifests/docs.json`: Lookbook pages with their raw source.

## Roadmap

1. **Done:** manifests, docs toolset, preview instructions, HTTP endpoint and info page, config, origin and token checks.
2. `previews-show`, `previews-find-by-component`, and `render-scenario` (rendered HTML with params).
3. `previews-check` (render every scenario and report errors), `previews-changed` (git diff mapped to previews),
   `rake lookbook:manifests` static export plus a read-only docs server for sharing,
   `Lookbook.add_mcp_tool` for host-app tools, stdio entry point.
4. axe accessibility checks via headless Chromium; inline previews via MCP Apps.

## Notes

- The transport is stateless: every `POST` returns a single JSON response, `GET` without
  `text/html` returns 405 (no SSE stream), and no `Mcp-Session-Id` is issued.
- Manifests are built per request from the in-memory preview and page collections,
  so they always reflect the reloaded state. Cache if this becomes slow on large libraries.
- Component descriptions come from the comment block above the class definition and
  argument descriptions from `@param` lines above `def initialize`.
