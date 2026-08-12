# News Gateway Precision Round 2

**Status**: Planned (not started)
**Design Reference**: `design-docs/specs/architecture.md`, `design-docs/specs/riela-node-integration.md#later-work-out-of-scope-here`

## Purpose

Remaining accuracy/robustness items from the project goal after round 1
(feed autodiscovery, item normalization, timeouts — see
`impl-plans/completed/news-gateway-precision-1.md`).

## Deliverables

- [ ] Politeness / rate limiting: minimum interval between requests to the
      same host (config `politeness.minIntervalMsPerHost`), applied inside
      the backend chain; no limiting between different hosts
- [ ] Strategy replay regression tests: store fixture strategies plus
      captured content under `Tests/AppCoreTests/Fixtures/`, execute each
      stored strategy against its captured content, and assert stable item
      output (guards against executor/normalizer regressions)
- [ ] Richer schema validation: enforce `format: uri` and
      `format: date-time` (post-normalization), `minLength`, and
      `maxItems`; violations keep feeding the learner repair loop
- [ ] Batch fetch for riela-scale use: `fetch --input-file urls.json`
      emitting one JSON document with per-URL results and errors, so a
      workflow node can process many sources in one process spawn

## Tasks

### TASK-001: Politeness

**Completion Criteria**:

- [ ] Same-host requests spaced by the configured interval (tested with an
      injected clock/sleeper); default off to keep current behavior

### TASK-002: Replay fixtures

**Completion Criteria**:

- [ ] At least one fixture per extraction kind (rss/css/json/llm) replayed
      deterministically in tests

### TASK-003: Schema validation depth

**Completion Criteria**:

- [ ] Validator covers format uri/date-time, minLength, maxItems with unit
      tests; executor drop-warnings mention the failed keyword

### TASK-004: Batch fetch

**Completion Criteria**:

- [ ] `fetch --input-file` contract documented in command.md and
      riela-node-integration.md before implementation; exit code reflects
      partial failure policy

## Progress Log

- 2026-08-12: Plan created after precision round 1 completed.
