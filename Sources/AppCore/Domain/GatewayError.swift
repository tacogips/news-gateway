import Foundation

/// Errors surfaced by the gateway. Cases map to stable CLI exit codes, see
/// design-docs/specs/command.md.
public enum GatewayError: Error, Sendable, Equatable, CustomStringConvertible {
  case noStrategy(sourceURL: String)
  case fetchFailed(sourceURL: String, attempts: Int, message: String)
  case learningFailed(sourceURL: String, message: String)
  case configuration(message: String)
  case backend(name: String, message: String)
  case extraction(message: String)
  case invalidInput(message: String)

  public var description: String {
    switch self {
    case .noStrategy(let sourceURL):
      return "No strategy stored for \(sourceURL); learn one first or pass --learn-if-missing"
    case .fetchFailed(let sourceURL, let attempts, let message):
      return "Fetch failed for \(sourceURL) after \(attempts) attempt(s): \(message)"
    case .learningFailed(let sourceURL, let message):
      return "Strategy learning failed for \(sourceURL): \(message)"
    case .configuration(let message):
      return "Configuration error: \(message)"
    case .backend(let name, let message):
      return "Backend \(name) failed: \(message)"
    case .extraction(let message):
      return "Extraction failed: \(message)"
    case .invalidInput(let message):
      return "Invalid input: \(message)"
    }
  }

  /// Stable machine-readable code used in CLI error JSON.
  public var code: String {
    switch self {
    case .noStrategy: return "no_strategy"
    case .fetchFailed: return "fetch_failed"
    case .learningFailed: return "learning_failed"
    case .configuration: return "configuration"
    case .backend: return "backend"
    case .extraction: return "extraction"
    case .invalidInput: return "invalid_input"
    }
  }
}
