# Resolved: agent-gateway invocation interface

## Question

How should news-gateway invoke the user's `agent-gateway` for strategy
learning and llm-kind extraction?

## Answer (2026-08-12)

The user pointed to their local checkout of
[tacogips/agent-gateway](https://github.com/tacogips/agent-gateway)
(public, tagged v0.1.2). It is a Swift
package and ACP (Agent Client Protocol) stdio agent exposing library
products `ACP`, `AgentGateway`, and `AgentGatewayAppCore`.

Decision: consume it as a SwiftPM dependency and host the agent in-process —
no subprocess, no JSONL parsing:

- `ACPClientConnection.inProcess(agent: GatewayACPAgent(defaults:))`
- `initialize` -> `newSession` -> `promptCollecting` -> `messageText`
- vendor/model/apiKeyEnvironment/baseURL/providerName/maxTokens come from
  the `llm` config section (`mode: "acp"`); the API key is resolved by
  agent-gateway from the process environment by NAME.
- `stopReason` `refusal`/`cancelled` and empty completions map to errors;
  `end_turn`/`max_tokens` are accepted (truncated JSON fails later in
  payload parsing, which feeds the learner's repair loop).

Implemented in `Sources/AppCore/LLM/ACPAgentGatewayLLMClient.swift`. The
previous `command` (stdin/stdout argv) and `http` (OpenAI-compatible) modes
remain as escape hatches.

## JSON output forcing

agent-gateway does not expose a JSON-mode parameter, so the learner keeps
its defensive extraction (code-fence stripping, brace matching) in
`LLMJSONPayload`.
