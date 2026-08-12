import Foundation
import Testing
@testable import AppCore

@Test func cssExtractionResolvesRelativeURLs() throws {
  let spec = CSSExtraction(
    itemSelector: "li.article",
    fields: [
      "title": .init(selector: "a"),
      "url": .init(selector: "a", attribute: "href", resolveURL: true)
    ]
  )
  let items = try CSSExtractor.extract(
    from: Fixtures.newsHTML,
    pageURL: "https://example.com/news",
    spec: spec,
    count: 2
  )
  #expect(items.count == 2)
  #expect(items[0]["title"] == .string("First article"))
  #expect(items[0]["url"] == .string("https://example.com/articles/first"))
  #expect(items[1]["url"] == .string("https://example.com/articles/second"))
}

@Test func rssExtractionUsesDefaultFieldMap() throws {
  let items = try RSSExtractor.extract(from: Fixtures.rssXML, spec: RSSExtraction(), count: 5)
  #expect(items.count == 2)
  #expect(items[0]["title"] == .string("Feed item one"))
  #expect(items[0]["url"] == .string("https://example.com/one"))
  #expect(items[0]["publishedAt"] == .string("Tue, 12 Aug 2026 09:00:00 GMT"))
  #expect(items[0]["summary"] == .string("Summary one"))
}

@Test func jsonExtractionMapsPaths() throws {
  let spec = JSONExtraction(
    itemsPath: "data.articles",
    fields: [
      "title": "headline",
      "url": "links.web",
      "publishedAt": "ts"
    ]
  )
  let items = try JSONExtractor.extract(from: Fixtures.apiJSON, spec: spec, count: 10)
  #expect(items.count == 2)
  #expect(items[0]["title"] == .string("API one"))
  #expect(items[0]["url"] == .string("https://example.com/api/1"))
}

@Test func executorValidatesAgainstSchemaAndTruncates() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", body: Fixtures.newsHTML)
  let registry = BackendRegistry(backends: [HTTPScrapingBackend(transport: transport)])
  let executor = StrategyExecutor(backends: registry)

  let strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: Date(timeIntervalSince1970: 0))
  let result = try await executor.executeOnce(strategy: strategy, count: 2)
  #expect(result.items.count == 2)
  #expect(result.backendUsed == .http)
}

@Test func executorFailsWhenAllBackendsFail() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://example.com/news", statusCode: 503, body: "down")
  let registry = BackendRegistry(backends: [HTTPScrapingBackend(transport: transport)])
  let executor = StrategyExecutor(backends: registry)
  let strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: Date(timeIntervalSince1970: 0))

  await #expect(throws: GatewayError.self) {
    _ = try await executor.executeOnce(strategy: strategy, count: 2)
  }
}
