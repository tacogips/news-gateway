# Riela Node Integration (Forward Design)

## Status

Draft (constraints adopted; node itself not yet implemented)

## Goal

`news-gateway` will later run as a node inside `tacogips/riela` workflows,
e.g. a Collector step that feeds URL lists in and gets item JSON out. The
current CLI and library are designed so that the node is a thin wrapper with
no changes to this package.

## Planned Node Shape

A riela node add-on (or command node) invoking the CLI:

- input: `{ "url": string, "count": number, "learnIfMissing": bool }`
  mapped to `news-gateway fetch <url> --count N --learn-if-missing`
- output: the `fetch` stdout JSON document, passed through as the node output
- failure: nonzero exit codes map to node failure; exit code and the stderr
  error JSON give the failure reason (see `command.md`)

## Constraints This Package Already Honors

1. Machine-readable stdout: exactly one JSON document, nothing else.
   Diagnostics and progress go to stderr.
2. Stable exit codes distinguishing "no strategy" (4), "fetch failed" (3),
   "learning failed" (5), and "config error" (6) so a workflow can branch.
3. Non-interactive: no prompts, no TTY assumptions.
4. Secrets via environment only (`FIRECRAWL_API_KEY`, `ZENROWS_API_KEY`,
   agent-gateway settings), which riela can inject per node via `addon.env`.
5. Config injectable via `--config` / `NEWS_GATEWAY_CONFIG`, DB path via
   `--db` / `NEWS_GATEWAY_DB`, so parallel nodes can isolate state.
6. Library alternative: `NewsGateway` is constructible from an in-memory
   `GatewayConfig` for an in-process embedding if riela gains Swift add-ons.

## Later Work (out of scope here)

- Publish a riela package bundling a workflow + node add-on that calls
  `news-gateway`.
- Batch mode (`fetch --input-file urls.json`) if per-URL process spawn cost
  matters in large workflows.
