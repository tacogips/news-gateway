import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequestSpec: Sendable, Equatable {
  public var method: String
  public var url: String
  public var headers: [String: String]
  public var body: Data?

  public init(method: String = "GET", url: String, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct HTTPResponseSpec: Sendable, Equatable {
  public var statusCode: Int
  public var body: Data

  public init(statusCode: Int, body: Data) {
    self.statusCode = statusCode
    self.body = body
  }

  public var bodyText: String {
    String(decoding: body, as: UTF8.self)
  }
}

/// Injection point for all HTTP; tests use an in-memory fake.
public protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec
}

public struct URLSessionTransport: HTTPTransport {
  private let timeoutSeconds: TimeInterval

  public init(timeoutSeconds: TimeInterval = 60) {
    self.timeoutSeconds = timeoutSeconds
  }

  public func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec {
    guard let url = URL(string: request.url) else {
      throw GatewayError.invalidInput(message: "Not a valid URL: \(request.url)")
    }
    var urlRequest = URLRequest(url: url, timeoutInterval: timeoutSeconds)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }

    let (data, response) = try await data(for: urlRequest)
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    return HTTPResponseSpec(statusCode: statusCode, body: data)
  }

  private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await withCheckedThrowingContinuation { continuation in
      let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, let response {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: GatewayError.backend(name: "http", message: "Empty response"))
        }
      }
      task.resume()
    }
  }
}
