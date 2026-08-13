import Foundation

/// Result of fetching the latest items from a source. This is the stable
/// JSON contract printed by `web-gateway fetch` and consumed by riela nodes.
public struct FetchOutput: Codable, Sendable, Equatable {
  public let sourceURL: String
  public let strategyID: String
  public let strategyVersion: Int
  public let fetchedAt: Date
  public let backendUsed: String
  public let items: [JSONValue]
  public let warnings: [String]

  public init(
    sourceURL: String,
    strategyID: String,
    strategyVersion: Int,
    fetchedAt: Date,
    backendUsed: String,
    items: [JSONValue],
    warnings: [String]
  ) {
    self.sourceURL = sourceURL
    self.strategyID = strategyID
    self.strategyVersion = strategyVersion
    self.fetchedAt = fetchedAt
    self.backendUsed = backendUsed
    self.items = items
    self.warnings = warnings
  }
}

/// Normalizes source URLs so lookups are stable across cosmetic variants.
public enum SourceURLNormalizer {
  public static func normalize(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed), components.scheme != nil, components.host != nil else {
      throw GatewayError.invalidInput(message: "Not an absolute URL: \(raw)")
    }
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    components.fragment = nil
    if components.path.count > 1, components.path.hasSuffix("/") {
      components.path = String(components.path.dropLast())
    }
    guard let normalized = components.string else {
      throw GatewayError.invalidInput(message: "Not a valid URL: \(raw)")
    }
    return normalized
  }
}
