import Foundation
import Testing
@testable import AppCore

@Test func storeSavesFindsAndDeletes() async throws {
  let store = try SQLiteStrategyStore(path: makeTempDBPath())
  let date = Date(timeIntervalSince1970: 1_000_000)
  let strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: date)

  try await store.save(strategy)
  let byURL = try await store.find(sourceURL: "https://example.com/news")
  #expect(byURL?.strategy == strategy)
  let byID = try await store.find(id: strategy.id)
  #expect(byID?.strategy == strategy)
  #expect(try await store.list().count == 1)

  #expect(try await store.delete(idOrURL: strategy.id))
  #expect(try await store.find(id: strategy.id) == nil)
  #expect(!(try await store.delete(idOrURL: strategy.id)))
}

@Test func storeArchivesRevisionsOnUpdate() async throws {
  let store = try SQLiteStrategyStore(path: makeTempDBPath())
  let date = Date(timeIntervalSince1970: 1_000_000)
  var strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: date)

  try await store.save(strategy)
  strategy.version = 2
  strategy.name = "Updated"
  strategy.updatedAt = date.addingTimeInterval(60)
  try await store.save(strategy)

  let stored = try await store.find(id: strategy.id)
  #expect(stored?.strategy.version == 2)
  #expect(stored?.strategy.name == "Updated")

  let revisions = try await store.revisions(strategyID: strategy.id)
  #expect(revisions.count == 1)
  #expect(revisions[0].version == 1)
  #expect(revisions[0].name == "Example CSS")
}

@Test func storeRecordsOutcomes() async throws {
  let store = try SQLiteStrategyStore(path: makeTempDBPath())
  let date = Date(timeIntervalSince1970: 1_000_000)
  let strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: date)
  try await store.save(strategy)

  try await store.recordOutcome(id: strategy.id, success: true, error: nil, at: date)
  try await store.recordOutcome(id: strategy.id, success: false, error: "boom", at: date.addingTimeInterval(10))

  let stored = try #require(try await store.find(id: strategy.id))
  #expect(stored.successCount == 1)
  #expect(stored.failureCount == 1)
  #expect(stored.lastError == "boom")
  #expect(stored.lastFetchedAt != nil)
}

@Test func storeFindsByIDOrURL() async throws {
  let store = try SQLiteStrategyStore(path: makeTempDBPath())
  let date = Date(timeIntervalSince1970: 1_000_000)
  let strategy = Fixtures.cssStrategy(sourceURL: "https://example.com/news", date: date)
  try await store.save(strategy)

  #expect(try await store.findByIDOrURL(strategy.id) != nil)
  #expect(try await store.findByIDOrURL("https://EXAMPLE.com/news/") != nil)
  #expect(try await store.findByIDOrURL("https://other.com/") == nil)
}
