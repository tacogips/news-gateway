# Architecture

## Status

Accepted — implemented and live-verified (core gateway, in-process
agent-gateway ACP integration, precision round 1: feed autodiscovery, item
normalization, timeouts). See `impl-plans/completed/` for the delivery
history.

## Purpose

`web-gateway` is a news collection gateway. Given a source URL, it fetches
the latest N items from that source. What makes it different from a plain
scraper is that it does not hard-code per-site parsing logic. Instead it uses
an LLM (through an agent gateway) once to *learn* how a given URL exposes its
latest items, and it persists that learned method as a *strategy* in SQLite.
Subsequent fetches execute the stored strategy deterministically, without an
LLM call, unless the strategy itself is of the LLM-extraction kind.

The motivation is a personal news pipeline (discovery, dedup, clustering,
ranking, synthesis). `web-gateway` is the Collector / Source Fetcher layer of
that pipeline: it must reliably answer "give me the latest N entries of this
URL as JSON that matches a known schema".

## Usage Surfaces

1. Library: the `AppCore` product exposes the `WebGateway` facade for direct
   embedding in other Swift programs.
2. CLI client: the `web-gateway` executable wraps the same facade with
   machine-readable JSON output.
3. Future: a node in `tacogips/riela` workflows. The riela node wraps the CLI
   (or calls the library). All CLI contracts (input flags, JSON output shape,
   exit codes) are therefore treated as stable public API. See
   `riela-node-integration.md`.

## Targets

- `CSQLite`: system library target exposing `sqlite3` (built-in on macOS,
  `libsqlite3-dev` on Linux).
- `AppCore`: the library. Domain models, strategy execution, learning,
  persistence, scraping backends, LLM client, gateway facade. No CLI parsing.
- `AppCLI`: `web-gateway` executable, built on `swift-argument-parser`.
- `AppCoreTests`: package tests. All external effects (network, processes,
  clock, sleeping, LLM) are behind protocols so tests run with fakes and no
  network.

External dependencies: `swift-argument-parser` (CLI), `SwiftSoup` (CSS
selector extraction, HTML stripping, feed autodiscovery), and
`tacogips/agent-gateway` (`ACP`, `AgentGateway`, `AgentGatewayAppCore`
products; the default in-process LLM path).

## Module Layout (Sources/AppCore)

- `Domain/`: `JSONValue` (arbitrary JSON), `SchemaValidator` (minimal JSON
  Schema subset), `FetchOutput`, `SourceURLNormalizer`, shared errors.
- `Strategy/`: `Strategy` model, `ExtractionSpec` (discriminated union),
  `StrategyExecutor`, extractors (`RSSExtractor`, `CSSExtractor`,
  `JSONExtractor`, LLM extraction), `ItemNormalizer` (+ `ItemDateParser`),
  `JSONPathExpression` (minimal dot/index paths).
- `Scraping/`: `ScrapingBackend` protocol, `HTTPScrapingBackend`,
  `FirecrawlBackend`, `ZenRowsBackend`, `KitesurfBackend`,
  `BackendRegistry`, `HTTPTransport` protocol (URLSession-backed by default),
  `ProcessRunner` protocol (timeout-enforcing subprocess execution).
- `LLM/`: `LLMClient` protocol, `ACPAgentGatewayLLMClient` (default:
  agent-gateway in-process over ACP), `AgentGatewayLLMClient` (command and
  http escape hatches), `LLMJSONPayload` (defensive JSON extraction).
- `Learning/`: `StrategyLearner` (propose -> execute -> validate -> repair
  loop), `LearningPrompt`, `FeedAutodiscovery`.
- `Persistence/`: `StrategyStore` protocol, `SQLiteStrategyStore` (actor),
  thin `SQLiteDatabase` wrapper over CSQLite.
- `Retry/`: `RetryPolicyConfig`, exponential backoff with jitter, `Sleeper`
  protocol.
- `Gateway/`: `WebGateway` facade, `GatewayConfig` (file + environment).

## Core Flow

```
fetchLatest(url, count)
  |
  v
StrategyStore.find(sourceURL)
  |-- none & learnIfMissing --> StrategyLearner.learn(url)
  |                                |
  |                                |  sample fetch (backend chain)
  |                                |  feed autodiscovery (link rel=alternate)
  |                                |  LLM proposes strategy JSON (via ACP)
  |                                |  execute proposal against live source
  |                                |  repair loop on failure (<= maxRounds)
  |                                v
  |                             StrategyStore.save
  v
StrategyExecutor.execute(strategy, count)     <- retry with backoff
  |   acquisition: backend chain fetches acquisition.url
  |   extraction: rss | css | json | llm  (over-fetch with slack)
  |   normalization: ISO 8601 dates, HTML strip, dedup, newest-first
  |   items validated against strategy.outputSchema, truncated to N
  v
FetchOutput { sourceURL, strategyID, items: [JSON], warnings }
  |
  |-- on persistent failure & relearnOnFailure --> learner.relearn + 1 retry
  v
StrategyStore.recordOutcome (success/failure counters, last error)
```

## Strategy

A strategy is the persisted answer to "how do I get the latest N items from
this URL, and what shape do the items have". Fields:

- `id`, `sourceURL` (normalized), `name`, `notes`, `version`
- `backends`: ordered backend names to try (`http`, `firecrawl`, `zenrows`,
  `playwright`, `kitesurf`, `agent-browser`)
- `acquisition`: URL to fetch (may differ from `sourceURL`, e.g. a discovered
  RSS feed or JSON API), format hint (`html` / `json` / `text`), `renderJS`,
  optional headers. The URL may contain `{count}` which is substituted at
  execution time.
- `extraction`: one of
  - `rss`: parse RSS/Atom via FoundationXML, map feed entry fields to schema
    fields
  - `css`: item CSS selector plus per-field selector/attribute rules
    (SwiftSoup)
  - `json`: JSON path to the items array plus per-field paths
  - `llm`: per-fetch LLM extraction with instructions (fallback for sites
    where no deterministic rule works)
- `outputSchema`: JSON Schema (subset) describing one item. The learner can
  be given a caller-provided schema, or it proposes one.
- `retry`: max attempts, initial delay, multiplier, max delay, jitter.

Strategies are updatable: `learn` with an existing strategy id keeps the id,
bumps `version`, and archives the previous body in a revisions table.

## Persistence (SQLite)

Single-file SQLite database (default
`~/.local/share/web-gateway/web-gateway.sqlite3`, overridable via config or
`WEB_GATEWAY_DB`). Tables:

- `strategies(id PK, source_url UNIQUE, name, body_json, version, created_at,
  updated_at, success_count, failure_count, last_error, last_fetched_at)`
- `strategy_revisions(id, strategy_id, version, body_json, created_at)`

The store is an actor; all SQL runs serialized. The full strategy is stored
as canonical JSON in `body_json`; columns exist only for lookup and stats.

## Backends

All backends implement `ScrapingBackend.fetch(ScrapeRequest) -> ScrapedContent`.

- `http`: plain URLSession GET. Default first choice.
- `firecrawl`: Firecrawl scrape API (`FIRECRAWL_API_KEY`).
- `zenrows`: ZenRows API (`ZENROWS_API_KEY`), supports `js_render`.
- `playwright`: runs the configured local Playwright command and reads the
  rendered HTML from stdout. The default command uses
  `scripts/playwright-fetch.mjs`.
- `kitesurf`: calls Cloudflare Browser Run's `/content` Quick Action with
  `browser=kitesurf`, using `CLOUDFLARE_ACCOUNT_ID` and
  `CLOUDFLARE_API_TOKEN` by default. This is the primary browser-rendering
  backend for JavaScript-dependent sources.
- `agent-browser`: opens the URL in an isolated local agent-browser session,
  extracts the final DOM, and closes the session after each fetch.

The executor walks the strategy's backend list in order and uses the first
success. API keys come only from environment variables named in config; they
are never persisted in strategies or the database. Local browser command
prefixes and timeouts are configurable under `playwright` and `agentBrowser`.

## LLM Access (agent-gateway)

`LLMClient` is a protocol with three implementations selected by `llm.mode`:

- `acp` (default): `tacogips/agent-gateway` consumed as a SwiftPM dependency
  and hosted in-process — `GatewayACPAgent` served over an in-memory ACP
  transport, one session per completion (`ACPAgentGatewayLLMClient`). Config
  carries `vendor` (anthropic, openai, gemini, openrouter, claude-code,
  codex, cursor, cursor-api), `model`, `apiKeyEnv` (environment variable
  name; the key is resolved by agent-gateway, never handled here), and
  optional `baseURL` / `providerName` / `maxTokens`.
- `command`: spawn a configured argv, prompt on stdin, completion on stdout
  (escape hatch for arbitrary local tools).
- `http`: POST an OpenAI-compatible `chat/completions` body to a configured
  endpoint.

See `design-docs/user-qa/qa-agent-gateway-interface.md` for the resolution
of the original interface question.

## Item Normalization

After extraction and before schema validation, `ItemNormalizer` applies:

- date normalization: fields marked `"format": "date-time"` in the output
  schema, plus conventional names (publishedAt, published, pubDate, ...),
  are parsed (ISO 8601, RFC 822, and common site formats) and rewritten as
  ISO 8601 UTC
- HTML stripping: markup and entities are removed from text fields; fields
  named url/link/id or marked `"format": "uri"` are never rewritten
- deduplication by url/link/id (first occurrence wins, warning emitted)
- newest-first ordering, applied only when every item has a parseable date

Extractors over-fetch (`count + max(count, 5)`) so dedup and validation
drops still leave `count` items after final truncation.

## Feed Autodiscovery (learning)

When the sampled source is an HTML page, the learner scans it for
`<link rel="alternate">` RSS/Atom/JSON-feed links, samples up to two
discovered feeds, and includes their URLs and content in the learning
prompt with an instruction to prefer a feed-based strategy. Feeds are the
most reliable extraction target, so this materially raises learning success
on real sites.

## Timeouts

- HTTP: URLSession request timeout (60s default).
- Kitesurf: uses the shared HTTP transport timeout (60s default).
- Command-mode LLM: 300s default. All subprocess execution goes through
  `ProcessRunner`, which enforces the deadline with a watchdog.

## Failure Handling

Every fetch attempt (acquisition + extraction + validation) is wrapped in a
retry loop with exponential backoff and jitter, bounded by the strategy's (or
call-site's) `maxAttempts`. Failures are recorded on the strategy. When
`relearnOnFailure` is set, a persistent failure triggers one re-learning round
with the failure message as feedback, then one final execution.

## Riela Readiness

Design constraints adopted now so the riela node is a thin wrapper later:

- All CLI outputs are single JSON documents on stdout when `--json` is given
  (fetch is always JSON); diagnostics go to stderr.
- Stable exit codes (see `command.md`).
- Fully non-interactive; secrets only via environment.
- The library facade (`WebGateway`) is initializable from an in-memory
  `GatewayConfig`, so an in-process node embedding needs no config file.
