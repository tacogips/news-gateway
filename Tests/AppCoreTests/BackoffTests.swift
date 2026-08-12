import Foundation
import Testing
@testable import AppCore

@Test func backoffDelaysGrowAndCap() {
  let config = RetryPolicyConfig(maxAttempts: 5, initialDelayMs: 100, multiplier: 2, maxDelayMs: 350, jitter: 0)
  #expect(Backoff.delayMilliseconds(forAttempt: 2, config: config) == 100)
  #expect(Backoff.delayMilliseconds(forAttempt: 3, config: config) == 200)
  #expect(Backoff.delayMilliseconds(forAttempt: 4, config: config) == 350)
  #expect(Backoff.delayMilliseconds(forAttempt: 5, config: config) == 350)
}

@Test func backoffJitterStaysWithinBounds() {
  let config = RetryPolicyConfig(maxAttempts: 2, initialDelayMs: 1_000, multiplier: 2, maxDelayMs: 10_000, jitter: 0.5)
  for _ in 0..<50 {
    let delay = Backoff.delayMilliseconds(forAttempt: 2, config: config)
    #expect(delay >= 500 && delay <= 1_500)
  }
}

@Test func withRetrySucceedsAfterFailures() async throws {
  let sleeper = FakeSleeper()
  let config = RetryPolicyConfig(maxAttempts: 4, initialDelayMs: 10, multiplier: 2, maxDelayMs: 100, jitter: 0)
  let (value, attempts) = try await Backoff.withRetry(config: config, sleeper: sleeper) { attempt in
    if attempt < 3 {
      throw GatewayError.extraction(message: "transient")
    }
    return "ok"
  }
  #expect(value == "ok")
  #expect(attempts == 3)
  let delays = await sleeper.delays
  #expect(delays == [10, 20])
}

@Test func withRetryThrowsAfterExhaustion() async throws {
  let sleeper = FakeSleeper()
  let config = RetryPolicyConfig(maxAttempts: 3, initialDelayMs: 5, multiplier: 2, maxDelayMs: 100, jitter: 0)
  do {
    _ = try await Backoff.withRetry(config: config, sleeper: sleeper) { _ -> String in
      throw GatewayError.extraction(message: "always")
    }
    Issue.record("Expected RetryExhausted")
  } catch let exhausted as Backoff.RetryExhausted {
    #expect(exhausted.attempts == 3)
  }
  let delays = await sleeper.delays
  #expect(delays.count == 2)
}
