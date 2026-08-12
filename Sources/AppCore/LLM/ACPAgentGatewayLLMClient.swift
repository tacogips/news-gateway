import ACP
import AgentGateway
import AgentGatewayAppCore
import Foundation

/// LLM access through agent-gateway hosted in-process: `GatewayACPAgent`
/// served over an in-memory ACP transport, one session per completion.
/// This is the default `llm.mode` (`acp`). Vendors are agent-gateway's
/// (`anthropic`, `openai`, `gemini`, `openrouter`, CLI agents, ...); the
/// API key is resolved by agent-gateway from the process environment via
/// `apiKeyEnvironment`, so secrets never pass through news-gateway.
public struct ACPAgentGatewayLLMClient: LLMClient {
  public struct Options: Sendable, Equatable {
    public var vendor: String
    public var model: String
    public var apiKeyEnvironment: String?
    public var baseURL: String?
    public var providerName: String?
    public var maxTokens: Int?

    public init(
      vendor: String,
      model: String,
      apiKeyEnvironment: String? = nil,
      baseURL: String? = nil,
      providerName: String? = nil,
      maxTokens: Int? = nil
    ) {
      self.vendor = vendor
      self.model = model
      self.apiKeyEnvironment = apiKeyEnvironment
      self.baseURL = baseURL
      self.providerName = providerName
      self.maxTokens = maxTokens
    }
  }

  private let options: Options
  private let makeAgent: @Sendable (_ systemPrompt: String?) -> any ACPAgent

  public init(options: Options) {
    self.init(options: options) { systemPrompt in
      GatewayACPAgent(
        defaults: GatewayAgentDefaults(
          vendor: GatewayVendor(rawValue: options.vendor),
          model: options.model,
          systemPrompt: systemPrompt,
          providerName: options.providerName,
          apiKeyEnvironment: options.apiKeyEnvironment,
          baseURL: options.baseURL,
          maxTokens: options.maxTokens
        )
      )
    }
  }

  /// Test seam: substitute a stub ACP agent.
  init(options: Options, makeAgent: @escaping @Sendable (_ systemPrompt: String?) -> any ACPAgent) {
    self.options = options
    self.makeAgent = makeAgent
  }

  public func complete(_ request: LLMRequest) async throws -> String {
    guard GatewayVendor(rawValue: options.vendor) != nil else {
      let valid = GatewayVendor.allCases.map(\.rawValue).joined(separator: ", ")
      throw GatewayError.configuration(
        message: "Unknown llm.vendor \"\(options.vendor)\"; valid vendors: \(valid)"
      )
    }

    let (client, _) = await ACPClientConnection.inProcess(agent: makeAgent(request.system))
    do {
      _ = try await client.initialize()
      let session = try await client.newSession(
        ACPNewSessionRequest(cwd: FileManager.default.currentDirectoryPath)
      )
      let result = try await client.promptCollecting(
        ACPPromptRequest(sessionId: session.sessionId, prompt: [.text(request.prompt)])
      )
      await client.stop()

      switch result.response.stopReason {
      case .endTurn, .maxTokens, .maxTurnRequests:
        break
      case .refusal:
        throw GatewayError.backend(name: "llm", message: "agent-gateway vendor refused the prompt")
      case .cancelled:
        throw GatewayError.backend(name: "llm", message: "agent-gateway turn was cancelled")
      }
      guard !result.messageText.isEmpty else {
        throw GatewayError.backend(name: "llm", message: "agent-gateway returned an empty completion")
      }
      return result.messageText
    } catch let error as GatewayError {
      await client.stop()
      throw error
    } catch {
      await client.stop()
      throw GatewayError.backend(name: "llm", message: "agent-gateway ACP call failed: \(error)")
    }
  }
}
