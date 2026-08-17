import Foundation
import Testing
@testable import AppCore

@Test func kitesurfFetchUsesBrowserRunContentEndpoint() async throws {
  let transport = FakeTransport()
  let endpoint = "https://api.cloudflare.com/client/v4/accounts/account-123/browser-run/content?browser=kitesurf"
  await transport.stub(
    url: endpoint,
    body: #"{"success":true,"result":"<html><body>Rendered</body></html>","meta":{"status":200}}"#
  )
  let backend = KitesurfBackend(
    transport: transport,
    accountID: "account-123",
    apiToken: "secret-token"
  )

  let content = try await backend.fetch(
    ScrapeRequest(url: "https://example.com/app", renderJS: true, headers: ["X-Test": "value"])
  )

  #expect(content.body == "<html><body>Rendered</body></html>")
  #expect(content.url == "https://example.com/app")
  #expect(content.statusCode == 200)
  let request = try #require(await transport.requests.first)
  #expect(request.method == "POST")
  #expect(request.headers["Authorization"] == "Bearer secret-token")
  let payload = try JSONValue(parsing: #require(request.body))
  #expect(payload["url"] == .string("https://example.com/app"))
  #expect(payload["setExtraHTTPHeaders"]?["X-Test"] == .string("value"))
}

@Test func kitesurfFetchSurfacesBrowserRunErrors() async throws {
  let transport = FakeTransport()
  let endpoint = "https://api.cloudflare.com/client/v4/accounts/account-123/browser-run/content?browser=kitesurf"
  await transport.stub(url: endpoint, body: #"{"success":false,"errors":[{"message":"render failed"}]}"#)
  let backend = KitesurfBackend(transport: transport, accountID: "account-123", apiToken: "secret-token")

  await #expect(throws: GatewayError.self) {
    try await backend.fetch(ScrapeRequest(url: "https://example.com/app", renderJS: true))
  }
}

@Test func browserBackendNamesRemainDistinctAndCodable() throws {
  let names: [BackendName] = [.playwright, .kitesurf, .agentBrowser]
  let encoded = try JSONCoding.encoder.encode(names)
  #expect(String(decoding: encoded, as: UTF8.self) == #"["playwright","kitesurf","agent-browser"]"#)
  #expect(try JSONCoding.decoder.decode([BackendName].self, from: encoded) == names)
}
