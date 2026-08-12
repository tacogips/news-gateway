# News Gateway Precision Round 1

**Status**: Completed
**Design Reference**: `design-docs/specs/architecture.md` (Item Normalization, Feed Autodiscovery, Timeouts)

## Purpose

Raise learning success rate and extraction correctness of the working
gateway: feed autodiscovery for the learner, deterministic item
normalization (ISO 8601 dates, HTML stripping, dedup, newest-first
ordering), and subprocess/backend timeouts.

## Deliverables

- [x] `ItemNormalizer` wired into `StrategyExecutor` (dates -> ISO 8601 UTC,
      HTML stripping with uri-field protection, dedup by url/link/id,
      newest-first sort only when all items are dated); extractors
      over-fetch so drops still fill `count`
- [x] `FeedAutodiscovery` (`link rel=alternate` RSS/Atom/JSON feed) + learner
      samples up to 2 feeds and feeds them into the learning prompt
- [x] `ProcessRunner` timeout with terminate watchdog; playwright backend
      timeout (config `playwright.timeoutSeconds`, default 120s); command
      LLM timeout (default 300s)
- [x] 12 new tests (normalizer, autodiscovery, learner prompt integration,
      backend fallback, llm-kind execution, process timeout) — 43 total
      passing, swiftlint clean

## Verification

- Live: stored gigazine.net strategy now returns ISO 8601 UTC dates,
  HTML-stripped summaries, and corrected newest-first ordering.
- Live: `strategy update https://gigazine.net/` re-learned with feed
  autodiscovery evidence (version 1 -> 2, same id, feed acquisition kept).

## Progress Log

- 2026-08-12: Implemented, tested, and live-verified. Completed.
