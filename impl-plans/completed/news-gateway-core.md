# News Gateway Core (strategy-learning fetch gateway)

**Status**: Completed
**Design Reference**: `design-docs/specs/architecture.md`, `design-docs/specs/command.md`, `design-docs/specs/riela-node-integration.md`

## Purpose

Turn the scaffold into the actual news collection gateway: fetch the latest N
items from a URL via pluggable scraping backends, learn per-source extraction
strategies with an LLM once, persist them in SQLite, execute them
deterministically with retry/backoff, and expose everything as both a library
(`AppCore`) and a CLI (`news-gateway`) with riela-node-ready JSON contracts.

## Deliverables

- [x] Design docs (architecture, command, riela integration, agent-gateway QA)
- [x] `CSQLite` system library target; SQLite-backed strategy store
- [x] Domain: `JSONValue`, minimal JSON Schema validation, `FetchOutput`
- [x] Strategy model (rss/css/json/llm extraction) + deterministic executor
- [x] Backends: http, firecrawl, zenrows, playwright-command; registry
- [x] LLM client protocol + agent-gateway command/http client
- [x] StrategyLearner with propose/execute/repair loop
- [x] Retry with exponential backoff and jitter (injectable sleeper)
- [x] `NewsGateway` facade + `GatewayConfig` (file + env)
- [x] CLI: fetch / strategy list-show-learn-update-delete / config init-show
- [x] Tests with fakes (no network); build + lint clean
- [x] Linux CI installs libsqlite3-dev
- [x] `scripts/playwright-fetch.mjs` sample fetch script

## Tasks

### TASK-001: AppCore foundations (Domain, Retry, Persistence)

**Parallelizable**: Yes

**Completion Criteria**:

- [x] JSONValue Codable roundtrip; schema validator covers type/required/
      properties/items/enum
- [x] SQLiteStrategyStore CRUD + revisions + outcome counters, tested against
      a temp-file DB

### TASK-002: Strategy execution and backends

**Parallelizable**: Yes

**Completion Criteria**:

- [x] Executor runs rss/css/json extraction on fixtures; llm extraction via
      injected fake client
- [x] Backend chain fallback order honored; API keys read from env only

### TASK-003: Learning and gateway facade

**Completion Criteria**:

- [x] Learner produces a stored strategy from a fake LLM proposal, repairs on
      first invalid proposal
- [x] fetchLatest: strategy lookup, learn-if-missing, backoff retries,
      relearn-on-failure, outcome recording

### TASK-004: CLI and CI

**Completion Criteria**:

- [x] Subcommands per command.md with stable exit codes; fetch prints one
      JSON document on stdout
- [x] swift build / swift test / swiftlint clean on macOS; Linux workflow
      updated for sqlite3 headers

## Progress Log

- 2026-08-12: Plan created; design docs written.
- 2026-08-12: Implemented AppCore (domain, strategy executor, extractors,
  SQLite store, backends, LLM client, learner, backoff, gateway facade),
  CLI subcommands, tests (26 passing), lint clean, Linux CI updated for
  libsqlite3-dev. Verified end to end against a live RSS source with a
  stubbed agent-gateway command. Plan completed.
- 2026-08-12: Resolved the agent-gateway interface question: added
  tacogips/agent-gateway v0.1.2 as a SwiftPM dependency and implemented the
  default `acp` LLM mode (GatewayACPAgent hosted in-process over an
  in-memory ACP transport). Verified live: gpt-5 via OpenRouter learned a
  strategy for gigazine.net (discovered the real RSS feed URL), and the
  stored strategy fetched current articles deterministically. 31 tests
  passing, lint clean.
