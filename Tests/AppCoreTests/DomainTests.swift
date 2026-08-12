import Foundation
import Testing
@testable import AppCore

@Test func jsonValueRoundTrips() throws {
  let original: JSONValue = .object([
    "title": .string("hello"),
    "count": .number(3),
    "flag": .bool(true),
    "nothing": .null,
    "tags": .array([.string("a"), .string("b")])
  ])
  let encoded = try original.encodedData()
  let decoded = try JSONValue(parsing: encoded)
  #expect(decoded == original)
}

@Test func jsonPathEvaluatesKeysAndIndexes() throws {
  let document = try JSONValue(parsing: Fixtures.apiJSON)
  let itemsPath = try JSONPathExpression("data.articles")
  let items = itemsPath.evaluate(on: document)?.arrayValue
  #expect(items?.count == 2)

  let first = try #require(items?.first)
  let headline = try JSONPathExpression("headline").evaluate(on: first)
  #expect(headline == .string("API one"))
  let web = try JSONPathExpression("links.web").evaluate(on: first)
  #expect(web == .string("https://example.com/api/1"))

  let indexed = try JSONPathExpression("$.data.articles[1].headline").evaluate(on: document)
  #expect(indexed == .string("API two"))
}

@Test func schemaValidatorChecksTypeAndRequired() {
  let valid: JSONValue = .object(["title": .string("t"), "url": .string("https://x")])
  #expect(SchemaValidator.validate(valid, against: Fixtures.itemSchema).isEmpty)

  let missingURL: JSONValue = .object(["title": .string("t")])
  let missingErrors = SchemaValidator.validate(missingURL, against: Fixtures.itemSchema)
  #expect(missingErrors.count == 1)
  #expect(missingErrors[0].contains("url"))

  let wrongType: JSONValue = .object(["title": .number(5), "url": .string("https://x")])
  let typeErrors = SchemaValidator.validate(wrongType, against: Fixtures.itemSchema)
  #expect(typeErrors.count == 1)
  #expect(typeErrors[0].contains("title"))
}

@Test func sourceURLNormalization() throws {
  #expect(try SourceURLNormalizer.normalize("HTTPS://Example.COM/News/") == "https://example.com/News")
  #expect(try SourceURLNormalizer.normalize("https://example.com/a#frag") == "https://example.com/a")
  #expect(throws: GatewayError.self) {
    try SourceURLNormalizer.normalize("not a url")
  }
}

@Test func extractionSpecCodableRoundTrip() throws {
  let spec = ExtractionSpec.css(
    CSSExtraction(itemSelector: "li", fields: ["title": .init(selector: "a")])
  )
  let data = try JSONCoding.encoder.encode(spec)
  let decoded = try JSONCoding.decoder.decode(ExtractionSpec.self, from: data)
  #expect(decoded == spec)
  #expect(String(decoding: data, as: UTF8.self).contains("\"kind\":\"css\""))
}

@Test func llmJSONPayloadHandlesFencesAndProse() throws {
  let fenced = "Here you go:\n```json\n{\"a\": 1}\n```\nDone."
  #expect(try LLMJSONPayload.extract(from: fenced) == .object(["a": .number(1)]))

  let bare = "{\"b\": true}"
  #expect(try LLMJSONPayload.extract(from: bare) == .object(["b": .bool(true)]))

  let embedded = "The result is {\"c\": [1, 2]} as requested."
  #expect(try LLMJSONPayload.extract(from: embedded) == .object(["c": .array([.number(1), .number(2)])]))

  #expect(throws: GatewayError.self) {
    _ = try LLMJSONPayload.extract(from: "no json here")
  }
}
