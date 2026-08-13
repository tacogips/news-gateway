import Foundation
@testable import AppCore

/// In-memory HTTP transport keyed by exact URL.
actor FakeTransport: HTTPTransport {
  struct Stub {
    var statusCode: Int
    var body: String
  }

  private var stubs: [String: Stub] = [:]
  private(set) var requests: [HTTPRequestSpec] = []

  func stub(url: String, statusCode: Int = 200, body: String) {
    stubs[url] = Stub(statusCode: statusCode, body: body)
  }

  func send(_ request: HTTPRequestSpec) async throws -> HTTPResponseSpec {
    requests.append(request)
    guard let stub = stubs[request.url] else {
      return HTTPResponseSpec(statusCode: 404, body: Data("not stubbed: \(request.url)".utf8))
    }
    return HTTPResponseSpec(statusCode: stub.statusCode, body: Data(stub.body.utf8))
  }
}

/// LLM client returning scripted completions in order.
actor FakeLLM: LLMClient {
  private var responses: [String]
  private(set) var prompts: [LLMRequest] = []

  init(responses: [String]) {
    self.responses = responses
  }

  func complete(_ request: LLMRequest) async throws -> String {
    prompts.append(request)
    guard !responses.isEmpty else {
      throw GatewayError.backend(name: "llm", message: "FakeLLM exhausted")
    }
    return responses.removeFirst()
  }
}

/// Records requested delays without sleeping.
actor FakeSleeper: Sleeper {
  private(set) var delays: [Int] = []

  func sleep(milliseconds: Int) async throws {
    delays.append(milliseconds)
  }
}

/// Process runner that must never be called.
struct UnusedProcessRunner: ProcessRunner {
  func run(command: [String], stdin: String?, timeoutSeconds: Int?) async throws -> ProcessResult {
    throw GatewayError.invalidInput(message: "Unexpected process invocation: \(command)")
  }
}

enum Fixtures {
  static let newsHTML = """
  <html><body>
    <ul>
      <li class="article"><a href="/articles/first">First article</a><time>2026-08-12</time></li>
      <li class="article"><a href="/articles/second">Second article</a><time>2026-08-11</time></li>
      <li class="article"><a href="/articles/third">Third article</a><time>2026-08-10</time></li>
    </ul>
  </body></html>
  """

  static let rssXML = """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0">
    <channel>
      <title>Example Feed</title>
      <item>
        <title>Feed item one</title>
        <link>https://example.com/one</link>
        <pubDate>Tue, 12 Aug 2026 09:00:00 GMT</pubDate>
        <description><![CDATA[Summary one]]></description>
        <guid>one</guid>
      </item>
      <item>
        <title>Feed item two</title>
        <link>https://example.com/two</link>
        <pubDate>Mon, 11 Aug 2026 09:00:00 GMT</pubDate>
        <description>Summary two</description>
        <guid>two</guid>
      </item>
    </channel>
  </rss>
  """

  static let apiJSON = """
  {
    "data": {
      "articles": [
        { "headline": "API one", "links": { "web": "https://example.com/api/1" }, "ts": "2026-08-12" },
        { "headline": "API two", "links": { "web": "https://example.com/api/2" }, "ts": "2026-08-11" }
      ]
    }
  }
  """

  static let itemSchema: JSONValue = .object([
    "type": .string("object"),
    "required": .array([.string("title"), .string("url")]),
    "properties": .object([
      "title": .object(["type": .string("string")]),
      "url": .object(["type": .string("string")])
    ])
  ])

  static func cssStrategy(sourceURL: String, date: Date) -> Strategy {
    Strategy(
      id: "css-strategy",
      sourceURL: sourceURL,
      name: "Example CSS",
      backends: [.http],
      acquisition: AcquisitionSpec(url: sourceURL, format: .html),
      extraction: .css(
        CSSExtraction(
          itemSelector: "li.article",
          fields: [
            "title": .init(selector: "a"),
            "url": .init(selector: "a", attribute: "href", resolveURL: true)
          ]
        )
      ),
      outputSchema: itemSchema,
      retry: RetryPolicyConfig(maxAttempts: 3, initialDelayMs: 100, multiplier: 2, maxDelayMs: 1_000, jitter: 0),
      createdAt: date,
      updatedAt: date
    )
  }

  static let validProposalJSON = """
  {
    "name": "Example news CSS strategy",
    "backends": ["http"],
    "acquisition": { "url": "https://example.com/news", "format": "html", "renderJS": false },
    "extraction": {
      "kind": "css",
      "css": {
        "itemSelector": "li.article",
        "fields": {
          "title": { "selector": "a" },
          "url": { "selector": "a", "attribute": "href", "resolveURL": true }
        }
      }
    },
    "outputSchema": {
      "type": "object",
      "required": ["title", "url"],
      "properties": {
        "title": { "type": "string" },
        "url": { "type": "string" }
      }
    }
  }
  """
}

func makeTempDBPath() -> String {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("web-gateway-tests-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory.appendingPathComponent("test.sqlite3").path
}
