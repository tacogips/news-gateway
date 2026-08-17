import Foundation

/// Runs a configurable Playwright command that writes rendered HTML to
/// stdout. The command template supports `{url}` and `{headers}` placeholders.
public struct PlaywrightCommandBackend: ScrapingBackend {
  public let name = BackendName.playwright
  private let runner: any ProcessRunner
  private let commandTemplate: [String]
  private let timeoutSeconds: Int

  public init(runner: any ProcessRunner, commandTemplate: [String], timeoutSeconds: Int = 120) {
    self.runner = runner
    self.commandTemplate = commandTemplate
    self.timeoutSeconds = timeoutSeconds
  }

  public func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent {
    guard !commandTemplate.isEmpty else {
      throw GatewayError.configuration(message: "playwright backend has no command configured")
    }
    let headers = try encodedHeaders(request.headers)
    let command = commandTemplate.map {
      $0
        .replacingOccurrences(of: "{url}", with: request.url)
        .replacingOccurrences(of: "{headers}", with: headers)
    }
    let result = try await runner.run(command: command, stdin: nil, timeoutSeconds: timeoutSeconds)
    guard result.exitCode == 0 else {
      throw commandError(name: "playwright", result: result)
    }
    guard !result.stdout.isEmpty else {
      throw GatewayError.backend(name: "playwright", message: "Command produced no output")
    }
    return ScrapedContent(url: request.url, body: result.stdout)
  }
}

/// Uses agent-browser's isolated sessions to render a URL and extract the
/// final DOM as HTML. Each fetch owns and closes its session, so concurrent
/// requests do not share page state.
public struct AgentBrowserBackend: ScrapingBackend {
  public let name = BackendName.agentBrowser
  private let runner: any ProcessRunner
  private let command: [String]
  private let timeoutSeconds: Int

  public init(runner: any ProcessRunner, command: [String] = ["agent-browser"], timeoutSeconds: Int = 120) {
    self.runner = runner
    self.command = command
    self.timeoutSeconds = timeoutSeconds
  }

  public func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent {
    guard !command.isEmpty else {
      throw GatewayError.configuration(message: "agent-browser backend has no command configured")
    }

    let session = "web-gateway-\(UUID().uuidString.lowercased())"
    do {
      var openArguments = ["--session", session, "--json"]
      if !request.headers.isEmpty {
        openArguments += ["--headers", try encodedHeaders(request.headers)]
      }
      openArguments += ["open", request.url]
      _ = try await run(arguments: openArguments, operation: "open")

      let script = Data("document.documentElement.outerHTML".utf8).base64EncodedString()
      let result = try await run(
        arguments: ["--session", session, "--json", "eval", "-b", script],
        operation: "extract HTML"
      )
      let body = try html(from: result.stdout)
      await close(session: session)
      return ScrapedContent(url: request.url, body: body)
    } catch {
      await close(session: session)
      throw error
    }
  }

  private func run(arguments: [String], operation: String) async throws -> ProcessResult {
    let result = try await runner.run(
      command: command + arguments,
      stdin: nil,
      timeoutSeconds: timeoutSeconds
    )
    guard result.exitCode == 0 else {
      throw commandError(name: "agent-browser", operation: operation, result: result)
    }
    let response = try agentBrowserResponse(from: result.stdout, operation: operation)
    guard response["success"]?.boolValue == true else {
      let message = response["error"]?.stringValue ?? response["message"]?.stringValue ?? "unknown error"
      throw GatewayError.backend(name: "agent-browser", message: "Could not \(operation): \(message)")
    }
    return result
  }

  private func html(from output: String) throws -> String {
    let response = try agentBrowserResponse(from: output, operation: "extract HTML")
    let body = response["data"]?["result"]?.stringValue
      ?? response["data"]?["value"]?.stringValue
      ?? response["result"]?.stringValue
    guard let body, !body.isEmpty else {
      throw GatewayError.backend(name: "agent-browser", message: "HTML extraction returned no content")
    }
    return body
  }

  private func agentBrowserResponse(from output: String, operation: String) throws -> JSONValue {
    do {
      return try JSONValue(parsing: Data(output.utf8))
    } catch {
      throw GatewayError.backend(
        name: "agent-browser",
        message: "Could not \(operation): invalid JSON response: \(output.prefix(300))"
      )
    }
  }

  private func close(session: String) async {
    _ = try? await runner.run(
      command: command + ["--session", session, "close"],
      stdin: nil,
      timeoutSeconds: 10
    )
  }
}

private func encodedHeaders(_ headers: [String: String]) throws -> String {
  String(decoding: try JSONCoding.encoder.encode(headers), as: UTF8.self)
}

private func commandError(name: String, operation: String? = nil, result: ProcessResult) -> GatewayError {
  let prefix = operation.map { "Could not \($0). " } ?? ""
  return GatewayError.backend(
    name: name,
    message: "\(prefix)Command exited with \(result.exitCode): \(result.stderr.prefix(300))"
  )
}
