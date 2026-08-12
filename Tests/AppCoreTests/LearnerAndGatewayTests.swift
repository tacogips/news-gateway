import Foundation
import Testing
@testable import AppCore

private func makeGateway(
  transport: FakeTransport,
  llm: FakeLLM,
  sleeper: FakeSleeper = FakeSleeper()
) throws -> NewsGateway {
  try NewsGateway(
    config: GatewayConfig(),
    environment: [:],
    transport: transport,
    processRunner: UnusedProcessRunner(),
    llm: llm,
    store: SQLiteStrategyStore(path: makeTempDBPath()),
    sleeper: sleeper,
    now: { Date(timeIntervalSince1970: 1_755_000_000) }
  )
}

@Test func learnerRepairsInvalidProposalThenSucceeds() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let llm = FakeLLM(responses: ["this is not json at all", Fixtures.validProposalJSON])
  let registry = BackendRegistry(backends: [HTTPScrapingBackend(transport: transport)])
  let executor = StrategyExecutor(backends: registry, llm: llm)
  let learner = StrategyLearner(
    llm: llm,
    executor: executor,
    defaultBackends: [.http],
    now: { Date(timeIntervalSince1970: 0) }
  )

  let strategy = try await learner.learn(LearningRequest(sourceURL: "https://example.com/news", count: 2))
  #expect(strategy.version == 1)
  #expect(strategy.extraction.kindName == "css")
  #expect(strategy.sourceURL == "https://example.com/news")

  // Second round's prompt should carry the failure feedback.
  let prompts = await llm.prompts
  #expect(prompts.count == 2)
  #expect(prompts[1].prompt.contains("Previous attempts failed"))
}

@Test func learnerFailsAfterMaxRounds() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let llm = FakeLLM(responses: ["bad", "bad", "bad"])
  let registry = BackendRegistry(backends: [HTTPScrapingBackend(transport: transport)])
  let executor = StrategyExecutor(backends: registry, llm: llm)
  let learner = StrategyLearner(llm: llm, executor: executor, defaultBackends: [.http], maxRounds: 3)

  do {
    _ = try await learner.learn(LearningRequest(sourceURL: "https://example.com/news", count: 2))
    Issue.record("Expected learningFailed")
  } catch let error as GatewayError {
    guard case .learningFailed = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
  }
}

@Test func gatewayLearnsOnDemandAndFetches() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let llm = FakeLLM(responses: [Fixtures.validProposalJSON])
  let gateway = try makeGateway(transport: transport, llm: llm)

  let output = try await gateway.fetchLatest(url: "https://example.com/news", count: 2, learnIfMissing: true)
  #expect(output.items.count == 2)
  #expect(output.items[0]["title"] == .string("First article"))
  #expect(output.items[0]["url"] == .string("https://example.com/articles/first"))
  #expect(output.backendUsed == "http")
  #expect(output.strategyVersion == 1)

  // Strategy persisted with a recorded success.
  let stored = try #require(try await gateway.strategy(idOrURL: "https://example.com/news"))
  #expect(stored.successCount == 1)

  // Second fetch reuses the stored strategy without any LLM call.
  let second = try await gateway.fetchLatest(url: "https://example.com/news", count: 1)
  #expect(second.items.count == 1)
  let prompts = await llm.prompts
  #expect(prompts.count == 1)
}

@Test func gatewayWithoutStrategyThrowsNoStrategy() async throws {
  let transport = FakeTransport()
  let llm = FakeLLM(responses: [])
  let gateway = try makeGateway(transport: transport, llm: llm)

  do {
    _ = try await gateway.fetchLatest(url: "https://example.com/none", count: 3)
    Issue.record("Expected noStrategy")
  } catch let error as GatewayError {
    guard case .noStrategy = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
  }
}

@Test func gatewayRetriesWithBackoffThenFails() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", statusCode: 500, body: "boom")
  let llm = FakeLLM(responses: [])
  let sleeper = FakeSleeper()
  let gateway = try makeGateway(transport: transport, llm: llm, sleeper: sleeper)

  // Seed a strategy directly through learnStrategy? The source is down, so
  // store one via a working sample first is impossible; instead exercise the
  // retry path by pre-saving through a second gateway sharing the same DB.
  let dbPath = makeTempDBPath()
  let store = try SQLiteStrategyStore(path: dbPath)
  let strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: Date(timeIntervalSince1970: 0))
  try await store.save(strategy)
  let gateway2 = try NewsGateway(
    config: GatewayConfig(),
    environment: [:],
    transport: transport,
    processRunner: UnusedProcessRunner(),
    llm: llm,
    store: store,
    sleeper: sleeper,
    now: { Date(timeIntervalSince1970: 1_755_000_000) }
  )
  _ = gateway

  do {
    _ = try await gateway2.fetchLatest(url: "https://example.com/news", count: 2)
    Issue.record("Expected fetchFailed")
  } catch let error as GatewayError {
    guard case .fetchFailed(_, let attempts, _) = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
    #expect(attempts == 3)
  }

  let delays = await sleeper.delays
  #expect(delays.count == 2)
  let stored = try #require(try await store.find(id: strategy.id))
  #expect(stored.failureCount == 1)
}

@Test func gatewayRelearnsOnFailure() async throws {
  let transport = FakeTransport()
  // The stored strategy points at a dead acquisition URL; the source page
  // itself works, so re-learning can propose the working strategy.
  await transport.stub(url: "https://example.com/old-endpoint", statusCode: 404, body: "gone")
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let llm = FakeLLM(responses: [Fixtures.validProposalJSON])
  let sleeper = FakeSleeper()

  let store = try SQLiteStrategyStore(path: makeTempDBPath())
  var broken = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: Date(timeIntervalSince1970: 0))
  broken.acquisition.url = "https://example.com/old-endpoint"
  try await store.save(broken)

  let gateway = try NewsGateway(
    config: GatewayConfig(),
    environment: [:],
    transport: transport,
    processRunner: UnusedProcessRunner(),
    llm: llm,
    store: store,
    sleeper: sleeper,
    now: { Date(timeIntervalSince1970: 1_755_000_000) }
  )

  let output = try await gateway.fetchLatest(
    url: "https://example.com/news",
    count: 2,
    relearnOnFailure: true
  )
  #expect(output.items.count == 2)
  #expect(output.strategyVersion == 2)

  let stored = try #require(try await store.find(sourceURL: "https://example.com/news"))
  #expect(stored.strategy.version == 2)
  #expect(stored.strategy.id == broken.id)
  #expect(stored.strategy.acquisition.url == "https://example.com/news")
  let revisions = try await store.revisions(strategyID: broken.id)
  #expect(revisions.count == 1)
}

@Test func gatewayLearnStrategyHonorsRequiredSchema() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let llm = FakeLLM(responses: [Fixtures.validProposalJSON])
  let gateway = try makeGateway(transport: transport, llm: llm)

  let schema = Fixtures.itemSchema
  let strategy = try await gateway.learnStrategy(url: "https://example.com/news", count: 2, outputSchema: schema)
  #expect(strategy.outputSchema == schema)

  let prompts = await llm.prompts
  #expect(prompts[0].prompt.contains("FIXED by the caller"))
}
