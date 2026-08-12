import Foundation

/// Injection point for delays so tests run instantly.
public protocol Sleeper: Sendable {
  func sleep(milliseconds: Int) async throws
}

public struct TaskSleeper: Sleeper {
  public init() {}

  public func sleep(milliseconds: Int) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
  }
}

public enum Backoff {
  /// Delay before the given retry (attempt 2 is the first retry).
  public static func delayMilliseconds(
    forAttempt attempt: Int,
    config: RetryPolicyConfig,
    random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
  ) -> Int {
    let exponent = max(0, attempt - 2)
    var delay = Double(config.initialDelayMs) * pow(config.multiplier, Double(exponent))
    delay = min(delay, Double(config.maxDelayMs))
    if config.jitter > 0 {
      let jitter = min(max(config.jitter, 0), 1)
      delay *= random(1 - jitter...1 + jitter)
    }
    return Int(delay.rounded())
  }

  /// Runs `operation` up to `config.maxAttempts` times with exponential
  /// backoff between attempts. Throws the last error with the attempt count.
  public static func withRetry<T: Sendable>(
    config: RetryPolicyConfig,
    sleeper: any Sleeper,
    operation: @Sendable (_ attempt: Int) async throws -> T
  ) async throws -> (result: T, attempts: Int) {
    let maxAttempts = max(1, config.maxAttempts)
    var lastError: Error = GatewayError.invalidInput(message: "Retry loop did not run")
    for attempt in 1...maxAttempts {
      if attempt > 1 {
        try await sleeper.sleep(milliseconds: delayMilliseconds(forAttempt: attempt, config: config))
      }
      do {
        let value = try await operation(attempt)
        return (value, attempt)
      } catch {
        lastError = error
      }
    }
    throw RetryExhausted(attempts: maxAttempts, lastError: lastError)
  }

  public struct RetryExhausted: Error, Sendable {
    public let attempts: Int
    public let lastError: Error
  }
}
