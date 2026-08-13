import Foundation

/// Cloudflare Browser Run Quick Actions backend using the Kitesurf browser.
public struct KitesurfBackend: ScrapingBackend {
  public let name = BackendName.kitesurf
  private let transport: any HTTPTransport
  private let accountID: String
  private let apiToken: String
  private let baseURL: String

  public init(
    transport: any HTTPTransport,
    accountID: String,
    apiToken: String,
    baseURL: String = "https://api.cloudflare.com/client/v4"
  ) {
    self.transport = transport
    self.accountID = accountID
    self.apiToken = apiToken
    self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  public func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent {
    let accountIDCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    guard
      let encodedAccountID = accountID.addingPercentEncoding(withAllowedCharacters: accountIDCharacters),
      !encodedAccountID.isEmpty
    else {
      throw GatewayError.configuration(message: "kitesurf backend has an invalid Cloudflare account ID")
    }

    var payload: [String: JSONValue] = ["url": .string(request.url)]
    if !request.headers.isEmpty {
      payload["setExtraHTTPHeaders"] = .object(request.headers.mapValues(JSONValue.string))
    }
    let response = try await transport.send(
      HTTPRequestSpec(
        method: "POST",
        url: "\(baseURL)/accounts/\(encodedAccountID)/browser-run/content?browser=kitesurf",
        headers: [
          "Authorization": "Bearer \(apiToken)",
          "Content-Type": "application/json"
        ],
        body: try JSONValue.object(payload).encodedData()
      )
    )
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.backend(
        name: "kitesurf",
        message: "HTTP \(response.statusCode): \(response.bodyText.prefix(300))"
      )
    }

    let (body, originStatusCode) = try decodedContent(from: response)
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayError.backend(name: "kitesurf", message: "Browser Run returned no content")
    }
    return ScrapedContent(url: request.url, body: body, statusCode: originStatusCode)
  }

  private func decodedContent(from response: HTTPResponseSpec) throws -> (String, Int?) {
    guard let value = try? JSONValue(parsing: response.body) else {
      return (response.bodyText, nil)
    }
    if let string = value.stringValue {
      return (string, nil)
    }
    if value["success"]?.boolValue == false {
      let messages = value["errors"]?.arrayValue?
        .compactMap { $0["message"]?.stringValue }
        .joined(separator: " | ")
      throw GatewayError.backend(name: "kitesurf", message: messages ?? "Browser Run request failed")
    }
    guard let result = value["result"]?.stringValue else {
      throw GatewayError.backend(name: "kitesurf", message: "Browser Run response contained no HTML result")
    }
    let statusCode = value["meta"]?["status"]?.numberValue.map(Int.init)
    return (result, statusCode)
  }
}
