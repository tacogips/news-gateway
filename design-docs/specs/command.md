# Command

## Status

Accepted (initial implementation)

## CLI

```
web-gateway fetch <url> [--count N] [--learn-if-missing] [--relearn-on-failure]
                         [--max-attempts N] [--pretty]
                         [--config PATH] [--db PATH]
web-gateway rest <url> [--method METHOD] [--parameter 'NAME=VALUE']
                       [--header 'NAME: VALUE']
                       [--auth none|bearer|basic|api-key]
                       [--body TEXT | --body-file PATH] [--pretty]
web-gateway strategy list [--json]
web-gateway strategy show <id-or-url> [--json]
web-gateway strategy learn <url> [--count N] [--hints TEXT]
                                  [--schema-file PATH]
web-gateway strategy update <id-or-url> [--count N] [--hints TEXT]
                                         [--schema-file PATH]
web-gateway strategy delete <id-or-url>
web-gateway config init [--path PATH] [--force]
web-gateway config show
web-gateway --version
```

Common options: `--config PATH` (default
`~/.config/web-gateway/config.json`, or `WEB_GATEWAY_CONFIG`), `--db PATH`
(overrides config; `WEB_GATEWAY_DB` also works), and `--llm-vendor NAME` /
`--llm-model NAME` (override the strategy-learning LLM configured in the
`llm` config section; `--llm-vendor` implies llm mode `acp`).

## Behavior

- `fetch`: loads (or learns, with `--learn-if-missing`) the strategy for the
  URL and prints a `FetchOutput` JSON document to stdout. Always JSON.
- `rest`: performs one direct HTTP request without a strategy, database, or
  LLM. It supports `GET`, `POST`, `QUERY`, and other valid HTTP method tokens,
  with repeatable URL query parameters. Successful response bytes are written
  to stdout. Authentication is selected with `--auth`; secrets are loaded from
  environment variables.
- `strategy learn`: learns and persists a strategy, printing the stored
  strategy as JSON. `--schema-file` supplies a required output JSON schema for
  the items; `--hints` passes free-text guidance to the learner.
- `strategy update`: re-learns an existing strategy (same id, version + 1),
  optionally with new hints/schema.
- `strategy list/show`: human-readable table/summary by default; `--json` for
  machine output.
- `config init`: writes a commented default config template.

## Output Contracts (stable; riela node relies on these)

`fetch` stdout:

```json
{
  "sourceURL": "https://example.com/news",
  "strategyID": "e6c0...",
  "strategyVersion": 3,
  "fetchedAt": "2026-08-12T09:00:00Z",
  "items": [ { "title": "...", "url": "...", "publishedAt": "..." } ],
  "warnings": ["..."]
}
```

`items` elements conform to the strategy's `outputSchema`.

Errors: a JSON object `{ "error": { "code": "...", "message": "..." } }` on
stderr plus a nonzero exit code.

## Exit Codes

- 0: success
- 2: usage / argument error
- 3: fetch failed after all retries
- 4: no strategy for URL (and `--learn-if-missing` not given)
- 5: strategy learning failed
- 6: configuration error (missing API key, bad config file)
- 1: other errors
