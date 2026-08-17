import Foundation

public enum RESTAuthentication: Sendable, Equatable {
  case none
  case bearer(token: String)
  case basic(username: String, password: String)
  case apiKey(header: String, value: String)
}

/// Secret-free authentication configuration. Request definitions store only
/// environment variable names and resolve credential values at execution time.
public enum RESTAuthenticationSource: Sendable, Equatable {
  case none
  case bearer(tokenEnvironment: String)
  case basic(usernameEnvironment: String, passwordEnvironment: String)
  case apiKey(header: String, valueEnvironment: String)

  public func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RESTAuthentication {
    switch self {
    case .none:
      return .none
    case .bearer(let tokenEnvironment):
      return .bearer(token: try credential(named: tokenEnvironment, environment: environment))
    case .basic(let usernameEnvironment, let passwordEnvironment):
      return .basic(
        username: try credential(named: usernameEnvironment, environment: environment),
        password: try credential(named: passwordEnvironment, environment: environment)
      )
    case .apiKey(let header, let valueEnvironment):
      return .apiKey(
        header: header,
        value: try credential(named: valueEnvironment, environment: environment)
      )
    }
  }

  private func credential(named name: String, environment: [String: String]) throws -> String {
    guard !name.isEmpty else {
      throw GatewayError.configuration(message: "Credential environment variable name is empty")
    }
    guard let value = environment[name], !value.isEmpty else {
      throw GatewayError.configuration(message: "Environment variable \(name) is not set or is empty")
    }
    return value
  }
}

public struct RESTQueryParameter: Sendable, Equatable {
  public var name: String
  public var value: String?

  public init(name: String, value: String? = nil) {
    self.name = name
    self.value = value
  }
}

public struct RESTRequest: Sendable, Equatable {
  public var method: String
  public var url: String
  public var parameters: [RESTQueryParameter]
  public var headers: [String: String]
  public var body: Data?
  public var authentication: RESTAuthentication

  public init(
    method: String = "GET",
    url: String,
    parameters: [RESTQueryParameter] = [],
    headers: [String: String] = [:],
    body: Data? = nil,
    authentication: RESTAuthentication = .none
  ) {
    self.method = method
    self.url = url
    self.parameters = parameters
    self.headers = headers
    self.body = body
    self.authentication = authentication
  }
}

/// A direct HTTP client for REST endpoints. Unlike strategy-backed fetching,
/// this performs exactly one request and does not use SQLite or an LLM.
public struct RESTClient: Sendable {
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport = URLSessionTransport()) {
    self.transport = transport
  }

  public func send(_ request: RESTRequest) async throws -> HTTPResponseSpec {
    let method = try validatedMethod(request.method)
    let url = try requestURL(baseURL: request.url, parameters: request.parameters)

    var headers = request.headers
    try apply(request.authentication, to: &headers)

    let response = try await transport.send(
      HTTPRequestSpec(method: method, url: url, headers: headers, body: request.body)
    )
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.backend(
        name: "rest",
        message: "HTTP \(response.statusCode) for \(url): \(response.bodyText.prefix(300))"
      )
    }
    return response
  }

  private func validatedMethod(_ method: String) throws -> String {
    let normalized = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty,
          normalized.unicodeScalars.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) || $0 == "-" }) else {
      throw GatewayError.invalidInput(message: "Invalid HTTP method: \(method)")
    }
    return normalized
  }

  private func requestURL(baseURL value: String, parameters: [RESTQueryParameter]) throws -> String {
    guard var components = URLComponents(string: value),
          let url = components.url,
          let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil else {
      throw GatewayError.invalidInput(message: "Not a valid HTTP(S) URL: \(value)")
    }
    guard parameters.allSatisfy({ !$0.name.isEmpty }) else {
      throw GatewayError.invalidInput(message: "REST query parameter names cannot be empty")
    }
    if !parameters.isEmpty {
      components.queryItems = (components.queryItems ?? []) + parameters.map {
        URLQueryItem(name: $0.name, value: $0.value)
      }
    }
    guard let result = components.url?.absoluteString else {
      throw GatewayError.invalidInput(message: "Could not add query parameters to URL: \(value)")
    }
    return result
  }

  private func apply(_ authentication: RESTAuthentication, to headers: inout [String: String]) throws {
    switch authentication {
    case .none:
      return
    case .bearer(let token):
      guard !token.isEmpty else {
        throw GatewayError.configuration(message: "Bearer token is empty")
      }
      setHeader(name: "Authorization", value: "Bearer \(token)", in: &headers)
    case .basic(let username, let password):
      guard !username.isEmpty else {
        throw GatewayError.configuration(message: "Basic authentication username is empty")
      }
      let credential = Data("\(username):\(password)".utf8).base64EncodedString()
      setHeader(name: "Authorization", value: "Basic \(credential)", in: &headers)
    case .apiKey(let header, let value):
      let header = header.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !header.isEmpty, !header.contains(":"), !header.contains("\n"), !header.contains("\r") else {
        throw GatewayError.invalidInput(message: "Invalid API key header name")
      }
      guard !value.isEmpty else {
        throw GatewayError.configuration(message: "API key is empty")
      }
      setHeader(name: header, value: value, in: &headers)
    }
  }

  private func setHeader(name: String, value: String, in headers: inout [String: String]) {
    if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
      headers.removeValue(forKey: existing)
    }
    headers[name] = value
  }
}
