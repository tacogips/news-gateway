import Foundation

/// Scraping backend identifiers a strategy can select.
public enum BackendName: String, Codable, Sendable, CaseIterable {
  case http
  case firecrawl
  case zenrows
  case kitesurf

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    if value == "playwright" {
      self = .kitesurf
      return
    }
    guard let backend = BackendName(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Unknown scraping backend: \(value)"
      )
    }
    self = backend
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Content format hint for acquisition and extraction.
public enum ContentFormat: String, Codable, Sendable {
  case html
  case json
  case text
}

/// How to obtain the raw content for a source. The URL may differ from the
/// strategy's `sourceURL` (a discovered feed or API endpoint) and may contain
/// `{count}` which is substituted at execution time.
public struct AcquisitionSpec: Codable, Sendable, Equatable {
  public var url: String
  public var format: ContentFormat
  public var renderJS: Bool
  public var headers: [String: String]?

  public init(url: String, format: ContentFormat, renderJS: Bool = false, headers: [String: String]? = nil) {
    self.url = url
    self.format = format
    self.renderJS = renderJS
    self.headers = headers
  }

  public func resolvedURL(count: Int) -> String {
    url.replacingOccurrences(of: "{count}", with: String(count))
  }
}

/// Retry behavior for fetch execution.
public struct RetryPolicyConfig: Codable, Sendable, Equatable {
  public var maxAttempts: Int
  public var initialDelayMs: Int
  public var multiplier: Double
  public var maxDelayMs: Int
  /// 0.0 ... 1.0 fraction of random jitter applied to each delay.
  public var jitter: Double

  public init(maxAttempts: Int, initialDelayMs: Int, multiplier: Double, maxDelayMs: Int, jitter: Double) {
    self.maxAttempts = maxAttempts
    self.initialDelayMs = initialDelayMs
    self.multiplier = multiplier
    self.maxDelayMs = maxDelayMs
    self.jitter = jitter
  }

  public static let `default` = RetryPolicyConfig(
    maxAttempts: 3,
    initialDelayMs: 500,
    multiplier: 2.0,
    maxDelayMs: 15_000,
    jitter: 0.2
  )
}

/// A learned, persisted method for fetching the latest N items of a source.
public struct Strategy: Codable, Sendable, Equatable {
  public var id: String
  public var sourceURL: String
  public var name: String
  public var notes: String?
  public var backends: [BackendName]
  public var acquisition: AcquisitionSpec
  public var extraction: ExtractionSpec
  /// JSON Schema (subset) describing one output item.
  public var outputSchema: JSONValue
  public var retry: RetryPolicyConfig
  public var version: Int
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    sourceURL: String,
    name: String,
    notes: String? = nil,
    backends: [BackendName],
    acquisition: AcquisitionSpec,
    extraction: ExtractionSpec,
    outputSchema: JSONValue,
    retry: RetryPolicyConfig = .default,
    version: Int = 1,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.sourceURL = sourceURL
    self.name = name
    self.notes = notes
    self.backends = backends
    self.acquisition = acquisition
    self.extraction = extraction
    self.outputSchema = outputSchema
    self.retry = retry
    self.version = version
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
