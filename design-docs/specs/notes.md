# Notes

Use this file for design notes that are not ready to become a dedicated
specification.

- 2026-08-12: Live verification uses OpenRouter (`openai/gpt-5`) because the
  local `ANTHROPIC_API_KEY` currently has no credit balance; the `acp` LLM
  mode itself works with any agent-gateway vendor.
- 2026-08-12: `LLMJSONPayload` keeps defensive JSON extraction (fences,
  brace matching) because agent-gateway exposes no JSON-mode parameter.
- Politeness/rate limiting, replay fixtures, deeper schema validation, and
  batch fetch are planned in `impl-plans/active/web-gateway-precision-2.md`.
