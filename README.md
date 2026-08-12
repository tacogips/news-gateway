# news-gateway

A news collection gateway. Given a source URL, it fetches the latest N items
as JSON. Instead of hard-coding per-site parsers, it uses an LLM (through
agent-gateway) once to learn how a source exposes its items, persists that
method as an updatable *strategy* in SQLite (including the output JSON
schema), and executes stored strategies deterministically with retry and
exponential backoff. Usable as a CLI client and as a Swift library
(`AppCore`), with JSON contracts designed for future use as a
`tacogips/riela` workflow node.

## Usage

```bash
# Learn a strategy for a source (uses the configured LLM), then fetch:
news-gateway fetch https://example.com/news --count 10 --learn-if-missing

# Manage strategies:
news-gateway strategy list
news-gateway strategy show https://example.com/news
news-gateway strategy learn https://example.com/news --hints "use the RSS feed" \
  --schema-file item-schema.json
news-gateway strategy update https://example.com/news
news-gateway strategy delete https://example.com/news

# Configuration (backends, LLM, retry defaults):
news-gateway config init
news-gateway config show
```

Scraping backends: plain HTTP (default), Firecrawl (`FIRECRAWL_API_KEY`),
ZenRows (`ZENROWS_API_KEY`), and a Playwright command adapter
(`scripts/playwright-fetch.mjs`). Strategies pick an ordered backend chain.

Strategy learning runs through
[tacogips/agent-gateway](https://github.com/tacogips/agent-gateway) hosted
in-process (ACP over an in-memory transport). Configure the vendor and model
in the `llm` section of the config:

```json
"llm": {
  "mode": "acp",
  "vendor": "anthropic",
  "model": "claude-sonnet-5",
  "apiKeyEnv": "ANTHROPIC_API_KEY"
}
```

Any agent-gateway vendor works (`anthropic`, `openai`, `gemini`,
`openrouter`, `claude-code`, `codex`, ...). `command` and `http` LLM modes
remain available as escape hatches.

Library use:

```swift
import AppCore

let gateway = try NewsGateway(config: .default)
let output = try await gateway.fetchLatest(
  url: "https://example.com/news", count: 10, learnIfMissing: true)
```

See `design-docs/specs/architecture.md` for the design and
`design-docs/specs/command.md` for the CLI/exit-code contracts.

## Development

```bash
mise install
mise run build
mise run test
swift run news-gateway --help
```

The package uses Swift Package Manager with:

- Library target: `AppCore`
- Executable target: `AppCLI`
- Installed executable: `news-gateway`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `AppCore`, `AppCLI`, and
`AppCommand` for Swift module/type variables.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap user/tap
brew install news-gateway
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
