import ACP
import Foundation
import Testing
@testable import AppCore

/// Minimal ACP agent standing in for GatewayACPAgent.
private struct StubACPAgent: ACPAgent {
  var reply: String
  var stopReason: ACPStopReason = .endTurn
  var receivedSystemPrompt: String?

  func initialize(_ request: ACPInitializeRequest) async throws -> ACPInitializeResponse {
    ACPInitializeResponse()
  }

  func newSession(
    _ request: ACPNewSessionRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPNewSessionResponse {
    ACPNewSessionResponse(sessionId: "sess-stub")
  }

  func prompt(
    _ request: ACPPromptRequest, connection: ACPAgentSideConnection
  ) async throws -> ACPPromptResponse {
    if !reply.isEmpty {
      await connection.sendUpdate(
        ACPSessionNotification(sessionId: request.sessionId, update: .agentMessageChunk(.text(reply)))
      )
    }
    return ACPPromptResponse(stopReason: stopReason)
  }

  func cancel(_ notification: ACPCancelNotification) async {}
}

private let stubOptions = ACPAgentGatewayLLMClient.Options(vendor: "anthropic", model: "claude-sonnet-5")

@Test func acpClientAggregatesMessageChunks() async throws {
  let client = ACPAgentGatewayLLMClient(options: stubOptions) { _ in
    StubACPAgent(reply: "{\"ok\": true}")
  }
  let completion = try await client.complete(LLMRequest(system: "sys", prompt: "hello"))
  #expect(completion == "{\"ok\": true}")
}

@Test func acpClientPassesSystemPromptToAgentFactory() async throws {
  // The factory receives the request's system prompt (it becomes
  // GatewayAgentDefaults.systemPrompt in production).
  nonisolated(unsafe) var seenSystem: String??
  let client = ACPAgentGatewayLLMClient(options: stubOptions) { system in
    seenSystem = system
    return StubACPAgent(reply: "ok")
  }
  _ = try await client.complete(LLMRequest(system: "you are a scraper", prompt: "p"))
  #expect(seenSystem == "you are a scraper")
}

@Test func acpClientRejectsUnknownVendor() async throws {
  let client = ACPAgentGatewayLLMClient(
    options: ACPAgentGatewayLLMClient.Options(vendor: "not-a-vendor", model: "m")
  ) { _ in
    StubACPAgent(reply: "unused")
  }
  do {
    _ = try await client.complete(LLMRequest(prompt: "p"))
    Issue.record("Expected configuration error")
  } catch let error as GatewayError {
    guard case .configuration = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
  }
}

@Test func acpClientMapsRefusalAndEmptyToErrors() async throws {
  let refusing = ACPAgentGatewayLLMClient(options: stubOptions) { _ in
    StubACPAgent(reply: "nope", stopReason: .refusal)
  }
  await #expect(throws: GatewayError.self) {
    _ = try await refusing.complete(LLMRequest(prompt: "p"))
  }

  let empty = ACPAgentGatewayLLMClient(options: stubOptions) { _ in
    StubACPAgent(reply: "")
  }
  await #expect(throws: GatewayError.self) {
    _ = try await empty.complete(LLMRequest(prompt: "p"))
  }
}

@Test func llmConfigDecodesACPMode() throws {
  let json = """
  { "llm": { "mode": "acp", "vendor": "openrouter", "model": "openai/gpt-5",
             "apiKeyEnv": "OPENROUTER_API_KEY", "maxTokens": 8000 } }
  """
  let config = try JSONCoding.decoder.decode(GatewayConfig.self, from: Data(json.utf8))
  #expect(config.llm.mode == .acp)
  #expect(config.llm.vendor == "openrouter")
  #expect(config.llm.model == "openai/gpt-5")
  #expect(config.llm.maxTokens == 8000)
}
