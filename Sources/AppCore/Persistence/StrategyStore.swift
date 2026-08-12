import Foundation

/// A strategy plus its execution statistics.
public struct StoredStrategy: Codable, Sendable, Equatable {
  public var strategy: Strategy
  public var successCount: Int
  public var failureCount: Int
  public var lastError: String?
  public var lastFetchedAt: Date?

  public init(
    strategy: Strategy,
    successCount: Int = 0,
    failureCount: Int = 0,
    lastError: String? = nil,
    lastFetchedAt: Date? = nil
  ) {
    self.strategy = strategy
    self.successCount = successCount
    self.failureCount = failureCount
    self.lastError = lastError
    self.lastFetchedAt = lastFetchedAt
  }
}

/// Persistence for learned strategies.
public protocol StrategyStore: Sendable {
  /// Upserts by id. When the id already exists, the previous body is
  /// archived as a revision.
  func save(_ strategy: Strategy) async throws
  func find(sourceURL: String) async throws -> StoredStrategy?
  func find(id: String) async throws -> StoredStrategy?
  func list() async throws -> [StoredStrategy]
  /// Returns true when something was deleted. Accepts an id or a source URL.
  func delete(idOrURL: String) async throws -> Bool
  func recordOutcome(id: String, success: Bool, error: String?, at date: Date) async throws
}

extension StrategyStore {
  /// Looks up by id first, then by normalized source URL.
  public func findByIDOrURL(_ idOrURL: String) async throws -> StoredStrategy? {
    if let byID = try await find(id: idOrURL) {
      return byID
    }
    guard let normalized = try? SourceURLNormalizer.normalize(idOrURL) else {
      return nil
    }
    return try await find(sourceURL: normalized)
  }
}
