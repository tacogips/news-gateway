import Foundation

public struct ScrapeRequest: Sendable, Equatable {
  public var url: String
  public var renderJS: Bool
  public var headers: [String: String]
  public var format: ContentFormat

  public init(url: String, renderJS: Bool = false, headers: [String: String] = [:], format: ContentFormat = .html) {
    self.url = url
    self.renderJS = renderJS
    self.headers = headers
    self.format = format
  }
}

public struct ScrapedContent: Sendable, Equatable {
  public var url: String
  public var body: String
  public var statusCode: Int?

  public init(url: String, body: String, statusCode: Int? = nil) {
    self.url = url
    self.body = body
    self.statusCode = statusCode
  }
}

/// A way to obtain raw content for a URL (plain HTTP, scraping API, headless
/// browser command).
public protocol ScrapingBackend: Sendable {
  var name: BackendName { get }
  func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent
}

/// Plain HTTP GET; the default first choice for feeds and static pages.
public struct HTTPScrapingBackend: ScrapingBackend {
  public let name = BackendName.http
  private let transport: any HTTPTransport
  private let userAgent: String

  public init(transport: any HTTPTransport, userAgent: String = "news-gateway/\(Version.current)") {
    self.transport = transport
    self.userAgent = userAgent
  }

  public func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent {
    var headers = request.headers
    if headers["User-Agent"] == nil {
      headers["User-Agent"] = userAgent
    }
    let response = try await transport.send(HTTPRequestSpec(url: request.url, headers: headers))
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.backend(name: "http", message: "HTTP \(response.statusCode) for \(request.url)")
    }
    return ScrapedContent(url: request.url, body: response.bodyText, statusCode: response.statusCode)
  }
}

/// Firecrawl scrape API (https://docs.firecrawl.dev). API key via env.
public struct FirecrawlBackend: ScrapingBackend {
  public let name = BackendName.firecrawl
  private let transport: any HTTPTransport
  private let apiKey: String
  private let baseURL: String

  public init(transport: any HTTPTransport, apiKey: String, baseURL: String = "https://api.firecrawl.dev") {
    self.transport = transport
    self.apiKey = apiKey
    self.baseURL = baseURL
  }

  public func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent {
    let payload: JSONValue = .object([
      "url": .string(request.url),
      "formats": .array([.string("html")])
    ])
    let httpRequest = HTTPRequestSpec(
      method: "POST",
      url: "\(baseURL)/v1/scrape",
      headers: [
        "Authorization": "Bearer \(apiKey)",
        "Content-Type": "application/json"
      ],
      body: try payload.encodedData()
    )
    let response = try await transport.send(httpRequest)
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.backend(name: "firecrawl", message: "HTTP \(response.statusCode): \(response.bodyText.prefix(300))")
    }
    let document = try JSONValue(parsing: response.body)
    let data = document["data"]
    guard
      let body = data?["html"]?.stringValue
        ?? data?["rawHtml"]?.stringValue
        ?? data?["markdown"]?.stringValue
    else {
      throw GatewayError.backend(name: "firecrawl", message: "Response contained no content")
    }
    return ScrapedContent(url: request.url, body: body, statusCode: response.statusCode)
  }
}

/// ZenRows API (https://docs.zenrows.com). API key via env.
public struct ZenRowsBackend: ScrapingBackend {
  public let name = BackendName.zenrows
  private let transport: any HTTPTransport
  private let apiKey: String
  private let baseURL: String

  public init(transport: any HTTPTransport, apiKey: String, baseURL: String = "https://api.zenrows.com") {
    self.transport = transport
    self.apiKey = apiKey
    self.baseURL = baseURL
  }

  public func fetch(_ request: ScrapeRequest) async throws -> ScrapedContent {
    var components = URLComponents(string: "\(baseURL)/v1/")
    components?.queryItems = [
      URLQueryItem(name: "apikey", value: apiKey),
      URLQueryItem(name: "url", value: request.url),
      URLQueryItem(name: "js_render", value: request.renderJS ? "true" : "false")
    ]
    guard let url = components?.string else {
      throw GatewayError.backend(name: "zenrows", message: "Could not build request URL")
    }
    let response = try await transport.send(HTTPRequestSpec(url: url))
    guard (200..<300).contains(response.statusCode) else {
      throw GatewayError.backend(name: "zenrows", message: "HTTP \(response.statusCode): \(response.bodyText.prefix(300))")
    }
    return ScrapedContent(url: request.url, body: response.bodyText, statusCode: response.statusCode)
  }
}

/// Resolves backend names to configured backend instances.
public struct BackendRegistry: Sendable {
  private let backends: [BackendName: any ScrapingBackend]

  public init(backends: [any ScrapingBackend]) {
    var map: [BackendName: any ScrapingBackend] = [:]
    for backend in backends {
      map[backend.name] = backend
    }
    self.backends = map
  }

  public func backend(named name: BackendName) throws -> any ScrapingBackend {
    guard let backend = backends[name] else {
      throw GatewayError.configuration(message: "Backend \(name.rawValue) is not configured (missing API key or command?)")
    }
    return backend
  }

  public var configuredNames: [BackendName] {
    Array(backends.keys)
  }
}
