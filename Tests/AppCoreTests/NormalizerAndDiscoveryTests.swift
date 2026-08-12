import Foundation
import Testing
@testable import AppCore

// MARK: - ItemNormalizer

@Test func normalizerConvertsDatesToISO8601() {
  var warnings: [String] = []
  let items: [JSONValue] = [
    .object([
      "title": .string("a"),
      "url": .string("https://x/1"),
      "publishedAt": .string("Tue, 12 Aug 2026 09:00:00 GMT")
    ])
  ]
  let result = ItemNormalizer.normalize(items: items, schema: Fixtures.itemSchema, warnings: &warnings)
  #expect(result[0]["publishedAt"] == .string("2026-08-12T09:00:00Z"))
}

@Test func normalizerHonorsSchemaDateTimeFormat() {
  var warnings: [String] = []
  let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "when": .object(["type": .string("string"), "format": .string("date-time")])
    ])
  ])
  let items: [JSONValue] = [.object(["when": .string("2026/08/12 10:30:00")])]
  let result = ItemNormalizer.normalize(items: items, schema: schema, warnings: &warnings)
  #expect(result[0]["when"] == .string("2026-08-12T10:30:00Z"))
}

@Test func normalizerStripsHTMLFromTextFieldsOnly() {
  var warnings: [String] = []
  let items: [JSONValue] = [
    .object([
      "title": .string("Big &amp; small"),
      "summary": .string("<p>Article URL: <a href=\"https://x\">link</a></p>\n<p>Points: 6</p>"),
      "url": .string("https://x/a?b=1&amp;c=2")
    ])
  ]
  let result = ItemNormalizer.normalize(items: items, schema: Fixtures.itemSchema, warnings: &warnings)
  #expect(result[0]["title"] == .string("Big & small"))
  #expect(result[0]["summary"] == .string("Article URL: link Points: 6"))
  // URL-ish fields are never rewritten.
  #expect(result[0]["url"] == .string("https://x/a?b=1&amp;c=2"))
}

@Test func normalizerDeduplicatesByURL() {
  var warnings: [String] = []
  let items: [JSONValue] = [
    .object(["title": .string("first"), "url": .string("https://x/1")]),
    .object(["title": .string("dup of first"), "url": .string("https://x/1")]),
    .object(["title": .string("second"), "url": .string("https://x/2")])
  ]
  let result = ItemNormalizer.normalize(items: items, schema: Fixtures.itemSchema, warnings: &warnings)
  #expect(result.count == 2)
  #expect(result[0]["title"] == .string("first"))
  #expect(warnings.contains { $0.contains("duplicate") })
}

@Test func normalizerSortsNewestFirstWhenAllDated() {
  var warnings: [String] = []
  let items: [JSONValue] = [
    .object(["title": .string("old"), "url": .string("https://x/1"), "publishedAt": .string("2026-08-10T00:00:00Z")]),
    .object(["title": .string("new"), "url": .string("https://x/2"), "publishedAt": .string("2026-08-12T00:00:00Z")]),
    .object(["title": .string("mid"), "url": .string("https://x/3"), "publishedAt": .string("2026-08-11T00:00:00Z")])
  ]
  let result = ItemNormalizer.normalize(items: items, schema: Fixtures.itemSchema, warnings: &warnings)
  #expect(result.map { $0["title"]?.stringValue } == ["new", "mid", "old"])
}

@Test func normalizerKeepsSourceOrderWhenDatesMissing() {
  var warnings: [String] = []
  let items: [JSONValue] = [
    .object(["title": .string("a"), "url": .string("https://x/1")]),
    .object(["title": .string("b"), "url": .string("https://x/2"), "publishedAt": .string("2026-08-12T00:00:00Z")])
  ]
  let result = ItemNormalizer.normalize(items: items, schema: Fixtures.itemSchema, warnings: &warnings)
  #expect(result.map { $0["title"]?.stringValue } == ["a", "b"])
}

// MARK: - Feed autodiscovery

private let pageWithFeeds = """
<!doctype html>
<html><head>
  <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
  <link rel="alternate" type="application/atom+xml" href="https://cdn.example.com/atom.xml">
  <link rel="stylesheet" href="/style.css">
</head><body><ul><li class="article"><a href="/a">A</a></li></ul></body></html>
"""

@Test func feedAutodiscoveryFindsAndResolvesFeedLinks() {
  let urls = FeedAutodiscovery.feedURLs(inHTML: pageWithFeeds, pageURL: "https://example.com/news")
  #expect(urls == ["https://example.com/feed.xml", "https://cdn.example.com/atom.xml"])
  #expect(FeedAutodiscovery.looksLikeHTMLPage(pageWithFeeds))
  #expect(!FeedAutodiscovery.looksLikeHTMLPage(Fixtures.rssXML))
}

@Test func learnerIncludesDiscoveredFeedsInPrompt() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: pageWithFeeds)
  await transport.stub(url: "https://example.com/feed.xml", body: Fixtures.rssXML)
  await transport.stub(url: "https://cdn.example.com/atom.xml", statusCode: 404, body: "gone")

  let proposal = """
  {
    "name": "Feed strategy",
    "backends": ["http"],
    "acquisition": { "url": "https://example.com/feed.xml", "format": "text", "renderJS": false },
    "extraction": { "kind": "rss", "rss": { "fieldMap": {} } },
    "outputSchema": { "type": "object", "required": ["title", "url"],
      "properties": { "title": { "type": "string" }, "url": { "type": "string" } } }
  }
  """
  let llm = FakeLLM(responses: [proposal])
  let registry = BackendRegistry(backends: [HTTPScrapingBackend(transport: transport)])
  let executor = StrategyExecutor(backends: registry, llm: llm)
  let learner = StrategyLearner(llm: llm, executor: executor, defaultBackends: [.http])

  let strategy = try await learner.learn(LearningRequest(sourceURL: "https://example.com/news", count: 2))
  #expect(strategy.acquisition.url == "https://example.com/feed.xml")

  let prompts = await llm.prompts
  #expect(prompts.count == 1)
  #expect(prompts[0].prompt.contains("Feed: https://example.com/feed.xml"))
  #expect(prompts[0].prompt.contains("Feed item one"))
}

// MARK: - Executor coverage

@Test func executorFallsBackToNextBackend() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://api.firecrawl.dev/v1/scrape", statusCode: 503, body: "down")
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)

  let registry = BackendRegistry(backends: [
    FirecrawlBackend(transport: transport, apiKey: "test-key"),
    HTTPScrapingBackend(transport: transport)
  ])
  let executor = StrategyExecutor(backends: registry)
  var strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: Date(timeIntervalSince1970: 0))
  strategy.backends = [.firecrawl, .http]

  let result = try await executor.executeOnce(strategy: strategy, count: 2)
  #expect(result.backendUsed == .http)
  #expect(result.items.count == 2)
}

@Test func executorRunsLLMExtractionKind() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let llm = FakeLLM(responses: [
    "[{\"title\": \"From LLM\", \"url\": \"https://example.com/a\"}]"
  ])
  let registry = BackendRegistry(backends: [HTTPScrapingBackend(transport: transport)])
  let executor = StrategyExecutor(backends: registry, llm: llm)

  var strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: Date(timeIntervalSince1970: 0))
  strategy.extraction = .llm(LLMExtraction(instructions: "extract items"))

  let result = try await executor.executeOnce(strategy: strategy, count: 5)
  #expect(result.items == [.object(["title": .string("From LLM"), "url": .string("https://example.com/a")])])
}

// MARK: - Process timeout

@Test func processRunnerEnforcesTimeout() async throws {
  let runner = FoundationProcessRunner()
  do {
    _ = try await runner.run(command: ["sh", "-c", "sleep 5"], stdin: nil, timeoutSeconds: 1)
    Issue.record("Expected timeout error")
  } catch let error as GatewayError {
    guard case .backend(_, let message) = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
    #expect(message.contains("timed out"))
  }
}

@Test func processRunnerCompletesWithinTimeout() async throws {
  let runner = FoundationProcessRunner()
  let result = try await runner.run(command: ["sh", "-c", "echo hello"], stdin: nil, timeoutSeconds: 10)
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("hello"))
}
