import Foundation
import Testing
@testable import AppCore

private struct AuthenticationExpectation {
  let authentication: RESTAuthentication
  let header: String
  let value: String
}

@Test func restAuthenticationSourceResolvesCustomEnvironmentVariableNames() throws {
  let environment = [
    "SERVICE_TOKEN": "bearer-secret",
    "SERVICE_USER": "alice",
    "SERVICE_PASSWORD": "password",
    "SERVICE_API_KEY": "key-secret"
  ]

  #expect(
    try RESTAuthenticationSource.bearer(tokenEnvironment: "SERVICE_TOKEN").resolve(environment: environment)
      == .bearer(token: "bearer-secret")
  )
  #expect(
    try RESTAuthenticationSource.basic(
      usernameEnvironment: "SERVICE_USER",
      passwordEnvironment: "SERVICE_PASSWORD"
    ).resolve(environment: environment) == .basic(username: "alice", password: "password")
  )
  #expect(
    try RESTAuthenticationSource.apiKey(
      header: "X-Custom-Key",
      valueEnvironment: "SERVICE_API_KEY"
    ).resolve(environment: environment) == .apiKey(header: "X-Custom-Key", value: "key-secret")
  )
}

@Test func restAuthenticationSourceRejectsMissingCredentialEnvironmentVariable() throws {
  do {
    _ = try RESTAuthenticationSource.bearer(tokenEnvironment: "MISSING_TOKEN").resolve(environment: [:])
    Issue.record("Expected configuration error")
  } catch let error as GatewayError {
    guard case .configuration(let message) = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
    #expect(message.contains("MISSING_TOKEN"))
  }
}

@Test func restClientSendsPlainGetRequest() async throws {
  let transport = FakeTransport()
  await transport.stub(url: "https://api.example.com/items", body: #"{"items":[]}"#)
  let client = RESTClient(transport: transport)

  let response = try await client.send(RESTRequest(url: "https://api.example.com/items"))

  #expect(response.statusCode == 200)
  let requests = await transport.requests
  #expect(requests.count == 1)
  #expect(requests[0].method == "GET")
  #expect(requests[0].headers["Authorization"] == nil)
}

@Test func restClientSwitchesAuthenticationModes() async throws {
  let url = "https://api.example.com/private"
  let expectations = [
    AuthenticationExpectation(
      authentication: .bearer(token: "secret-token"),
      header: "Authorization",
      value: "Bearer secret-token"
    ),
    AuthenticationExpectation(
      authentication: .basic(username: "alice", password: "password"),
      header: "Authorization",
      value: "Basic YWxpY2U6cGFzc3dvcmQ="
    ),
    AuthenticationExpectation(
      authentication: .apiKey(header: "X-Service-Key", value: "service-secret"),
      header: "X-Service-Key",
      value: "service-secret"
    )
  ]

  for expectation in expectations {
    let transport = FakeTransport()
    await transport.stub(url: url, body: "{}")
    let client = RESTClient(transport: transport)

    _ = try await client.send(RESTRequest(url: url, authentication: expectation.authentication))

    let request = try #require(await transport.requests.first)
    #expect(request.headers[expectation.header] == expectation.value)
  }
}

@Test func restClientSendsMethodHeadersAndBody() async throws {
  let transport = FakeTransport()
  let url = "https://api.example.com/items"
  await transport.stub(url: url, statusCode: 201, body: #"{"id":1}"#)
  let client = RESTClient(transport: transport)

  _ = try await client.send(
    RESTRequest(
      method: "post",
      url: url,
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"name":"new"}"#.utf8)
    )
  )

  let request = try #require(await transport.requests.first)
  #expect(request.method == "POST")
  #expect(request.headers["Content-Type"] == "application/json")
  #expect(request.body == Data(#"{"name":"new"}"#.utf8))
}

@Test func restClientAppendsParametersAndSupportsQueryMethod() async throws {
  let transport = FakeTransport()
  let expectedURL = "https://api.example.com/search?existing=yes&q=swift%20http&tag=one&tag=two"
  await transport.stub(url: expectedURL, body: #"{"items":[]}"#)
  let client = RESTClient(transport: transport)

  _ = try await client.send(
    RESTRequest(
      method: "QUERY",
      url: "https://api.example.com/search?existing=yes",
      parameters: [
        RESTQueryParameter(name: "q", value: "swift http"),
        RESTQueryParameter(name: "tag", value: "one"),
        RESTQueryParameter(name: "tag", value: "two")
      ],
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"filter":"recent"}"#.utf8)
    )
  )

  let request = try #require(await transport.requests.first)
  #expect(request.method == "QUERY")
  #expect(request.url == expectedURL)
  #expect(request.body == Data(#"{"filter":"recent"}"#.utf8))
}

@Test func restClientRejectsInvalidURLBeforeSending() async throws {
  let transport = FakeTransport()
  let client = RESTClient(transport: transport)

  do {
    _ = try await client.send(RESTRequest(url: "file:///tmp/data.json"))
    Issue.record("Expected invalidInput")
  } catch let error as GatewayError {
    guard case .invalidInput = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
  }

  #expect(await transport.requests.isEmpty)
}

@Test func restClientRejectsNonSuccessStatus() async throws {
  let transport = FakeTransport()
  let url = "https://api.example.com/items"
  await transport.stub(url: url, statusCode: 401, body: "unauthorized")
  let client = RESTClient(transport: transport)

  do {
    _ = try await client.send(RESTRequest(url: url))
    Issue.record("Expected backend error")
  } catch let error as GatewayError {
    guard case .backend(let name, let message) = error else {
      Issue.record("Unexpected error: \(error)")
      return
    }
    #expect(name == "rest")
    #expect(message.contains("HTTP 401"))
  }
}
