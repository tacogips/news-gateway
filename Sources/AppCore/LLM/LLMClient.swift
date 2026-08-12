import Foundation

public struct LLMRequest: Sendable, Equatable {
  public var system: String?
  public var prompt: String

  public init(system: String? = nil, prompt: String) {
    self.system = system
    self.prompt = prompt
  }
}

/// LLM access used for strategy learning and llm-kind extraction. The
/// completion is expected to be plain text; JSON payloads are extracted
/// defensively by the caller.
public protocol LLMClient: Sendable {
  func complete(_ request: LLMRequest) async throws -> String
}

/// Client for the user's agent-gateway. Two modes:
/// - command: spawn an argv, prompt on stdin, completion on stdout
/// - http: OpenAI-compatible chat/completions endpoint
/// See design-docs/user-qa/pending-agent-gateway-interface.md.
public struct AgentGatewayLLMClient: LLMClient {
  public enum Mode: Sendable, Equatable {
    case command([String])
    case http(endpoint: String, model: String, apiKey: String?)
  }

  private let mode: Mode
  private let runner: any ProcessRunner
  private let transport: any HTTPTransport
  private let commandTimeoutSeconds: Int

  public init(mode: Mode, runner: any ProcessRunner, transport: any HTTPTransport, commandTimeoutSeconds: Int = 300) {
    self.mode = mode
    self.runner = runner
    self.transport = transport
    self.commandTimeoutSeconds = commandTimeoutSeconds
  }

  public func complete(_ request: LLMRequest) async throws -> String {
    switch mode {
    case .command(let argv):
      return try await completeViaCommand(argv: argv, request: request)
    case .http(let endpoint, let model, let apiKey):
      return try await completeViaHTTP(endpoint: endpoint, model: model, apiKey: apiKey, request: request)
    }
  }

  private func completeViaCommand(argv: [String], request: LLMRequest) async throws -> String {
    guard !argv.isEmpty else {
      throw GatewayError.configuration(message: "llm.command is empty")
    }
    var input = ""
    if let system = request.system {
      input += system + "\n\n"
    }
    input += request.prompt
    let result = try await runner.run(command: argv, stdin: input, timeoutSeconds: commandTimeoutSeconds)
    guard result.exitCode == 0 else {
      throw GatewayError.backend(
        name: "llm",
        message: "agent-gateway exited with \(result.exitCode): \(result.stderr.prefix(500))"
      )
    }
    return result.stdout
  }

  private func completeViaHTTP(endpoint: String, model: String, apiKey: String?, request: LLMRequest) async throws -> String {
    var messages: [JSONValue] = []
    if let system = request.system {
      messages.append(.object(["role": .string("system"), "content": .string(system)]))
    }
    messages.append(.object(["role": .string("user"), "content": .string(request.prompt)]))
    let payload: JSONValue = .object([
      "model": .string(model),
      "messages": .array(messages)
    ])

    var headers = ["Content-Type": "application/json"]
    if let apiKey {
      headers["Authorization"] = "Bearer \(apiKey)"
    }
    let response = try await transport.send(
      HTTPRequestSpec(method: "POST", url: endpoint, headers: headers, body: try payload.encodedData())
    )
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.backend(name: "llm", message: "HTTP \(response.statusCode): \(response.bodyText.prefix(500))")
    }
    let document = try JSONValue(parsing: response.body)
    guard let content = document["choices"]?[0]?["message"]?["content"]?.stringValue else {
      throw GatewayError.backend(name: "llm", message: "Response contained no message content")
    }
    return content
  }
}

/// Utilities for pulling JSON out of LLM completions that may include prose
/// or markdown code fences.
public enum LLMJSONPayload {
  public static func extract(from completion: String) throws -> JSONValue {
    let trimmed = completion.trimmingCharacters(in: .whitespacesAndNewlines)

    if let fenced = fencedBlock(in: trimmed), let value = try? JSONValue(parsing: fenced) {
      return value
    }
    if let value = try? JSONValue(parsing: trimmed) {
      return value
    }
    for opener: Character in ["{", "["] {
      let closer: Character = opener == "{" ? "}" : "]"
      if let start = trimmed.firstIndex(of: opener), let end = trimmed.lastIndex(of: closer), start < end {
        let candidate = String(trimmed[start...end])
        if let value = try? JSONValue(parsing: candidate) {
          return value
        }
      }
    }
    throw GatewayError.extraction(message: "LLM completion contained no parseable JSON")
  }

  private static func fencedBlock(in text: String) -> String? {
    guard let fenceStart = text.range(of: "```") else { return nil }
    let afterFence = text[fenceStart.upperBound...]
    guard let lineBreak = afterFence.firstIndex(of: "\n") else { return nil }
    let body = afterFence[afterFence.index(after: lineBreak)...]
    guard let fenceEnd = body.range(of: "```") else { return nil }
    return String(body[..<fenceEnd.lowerBound])
  }
}
