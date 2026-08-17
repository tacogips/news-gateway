import AppCore
import ArgumentParser
import Foundation

enum RESTAuthMode: String, CaseIterable, ExpressibleByArgument {
  case none
  case bearer
  case basic
  case apiKey = "api-key"
}

struct RESTCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rest",
    abstract: "Send a direct HTTP request to a REST API without a stored strategy."
  )

  @Argument(help: "HTTP(S) endpoint URL")
  var url: String

  @Option(name: .long, help: "HTTP method")
  var method = "GET"

  @Option(name: .long, help: "Authentication mode: none, bearer, basic, or api-key")
  var auth: RESTAuthMode = .none

  @Option(name: .long, help: "Environment variable containing the Bearer token")
  var tokenEnv = "REST_API_TOKEN"

  @Option(name: .long, help: "Environment variable containing the Basic auth username")
  var usernameEnv = "REST_API_USERNAME"

  @Option(name: .long, help: "Environment variable containing the Basic auth password")
  var passwordEnv = "REST_API_PASSWORD"

  @Option(name: .long, help: "Environment variable containing the API key")
  var apiKeyEnv = "REST_API_KEY"

  @Option(name: .long, help: "Header used for api-key authentication")
  var apiKeyHeader = "X-API-Key"

  @Option(name: .customLong("header"), help: "Request header as 'Name: Value'; repeat for multiple headers")
  var headerValues: [String] = []

  @Option(name: .customLong("parameter"), help: "URL query parameter as 'Name=Value'; repeat for multiple parameters")
  var parameterValues: [String] = []

  @Option(name: .long, help: "UTF-8 request body")
  var body: String?

  @Option(name: .long, help: "Read the request body from a file")
  var bodyFile: String?

  @Option(name: .long, help: "Request timeout in seconds")
  var timeout: Double = 60

  @Flag(name: .long, help: "Pretty-print JSON responses")
  var pretty = false

  mutating func validate() throws {
    if body != nil, bodyFile != nil {
      throw ValidationError("Use either --body or --body-file, not both.")
    }
    if timeout <= 0 {
      throw ValidationError("--timeout must be greater than zero.")
    }
  }

  func run() async throws {
    try await runReportingErrors {
      let environment = ProcessInfo.processInfo.environment
      let request = RESTRequest(
        method: method,
        url: url,
        parameters: try parseParameters(),
        headers: try parseHeaders(),
        body: try requestBody(),
        authentication: try authentication(environment: environment)
      )
      let response = try await RESTClient(
        transport: URLSessionTransport(timeoutSeconds: timeout)
      ).send(request)
      try printBody(response.body)
    }
  }

  private func authentication(environment: [String: String]) throws -> RESTAuthentication {
    let source: RESTAuthenticationSource = switch auth {
    case .none:
      .none
    case .bearer:
      .bearer(tokenEnvironment: tokenEnv)
    case .basic:
      .basic(
        usernameEnvironment: usernameEnv,
        passwordEnvironment: passwordEnv
      )
    case .apiKey:
      .apiKey(
        header: apiKeyHeader,
        valueEnvironment: apiKeyEnv
      )
    }
    return try source.resolve(environment: environment)
  }

  private func parseHeaders() throws -> [String: String] {
    try headerValues.reduce(into: [:]) { headers, value in
      guard let separator = value.firstIndex(of: ":") else {
        throw GatewayError.invalidInput(message: "Header must use 'Name: Value': \(value)")
      }
      let name = value[..<separator].trimmingCharacters(in: .whitespaces)
      let headerValue = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else {
        throw GatewayError.invalidInput(message: "Header name cannot be empty")
      }
      headers[name] = headerValue
    }
  }

  private func parseParameters() throws -> [RESTQueryParameter] {
    try parameterValues.map { value in
      if let separator = value.firstIndex(of: "=") {
        let name = String(value[..<separator])
        guard !name.isEmpty else {
          throw GatewayError.invalidInput(message: "Query parameter name cannot be empty")
        }
        return RESTQueryParameter(name: name, value: String(value[value.index(after: separator)...]))
      }
      guard !value.isEmpty else {
        throw GatewayError.invalidInput(message: "Query parameter name cannot be empty")
      }
      return RESTQueryParameter(name: value)
    }
  }

  private func requestBody() throws -> Data? {
    if let body {
      return Data(body.utf8)
    }
    guard let bodyFile else { return nil }
    let path = GatewayConfig.expand(bodyFile)
    guard let data = FileManager.default.contents(atPath: path) else {
      throw GatewayError.invalidInput(message: "Body file not found: \(path)")
    }
    return data
  }

  private func printBody(_ data: Data) throws {
    let output: Data
    if pretty, let json = try? JSONValue(parsing: data) {
      output = try JSONCoding.prettyEncoder.encode(json)
    } else {
      output = data
    }
    FileHandle.standardOutput.write(output)
    if output.last != UInt8(ascii: "\n") {
      FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
    }
  }
}
