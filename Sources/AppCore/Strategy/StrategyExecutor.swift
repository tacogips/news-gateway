import Foundation

/// One successful strategy execution.
public struct ExecutionResult: Sendable, Equatable {
  public var items: [JSONValue]
  public var warnings: [String]
  public var backendUsed: BackendName

  public init(items: [JSONValue], warnings: [String], backendUsed: BackendName) {
    self.items = items
    self.warnings = warnings
    self.backendUsed = backendUsed
  }
}

/// Executes a stored strategy deterministically: acquire content through the
/// strategy's backend chain, extract items, validate them against the output
/// schema, and truncate to the requested count. No LLM calls unless the
/// strategy's extraction kind is `llm`.
public struct StrategyExecutor: Sendable {
  private let backends: BackendRegistry
  private let llm: (any LLMClient)?
  private let contentMaxChars: Int

  public init(backends: BackendRegistry, llm: (any LLMClient)? = nil, contentMaxChars: Int = 60_000) {
    self.backends = backends
    self.llm = llm
    self.contentMaxChars = contentMaxChars
  }

  public func executeOnce(strategy: Strategy, count: Int) async throws -> ExecutionResult {
    guard count > 0 else {
      throw GatewayError.invalidInput(message: "count must be positive")
    }
    let (content, backendUsed) = try await acquire(strategy: strategy, count: count)
    // Extract with slack so dedup/validation drops still leave `count` items.
    let extractCount = count + max(count, 5)
    let rawExtracted = try await extract(strategy: strategy, content: content, count: extractCount)

    var warnings: [String] = []
    let extracted = ItemNormalizer.normalize(
      items: rawExtracted,
      schema: strategy.outputSchema,
      warnings: &warnings
    )

    var valid: [JSONValue] = []
    for (index, item) in extracted.enumerated() {
      let violations = SchemaValidator.validate(item, against: strategy.outputSchema)
      if violations.isEmpty {
        valid.append(item)
      } else {
        warnings.append("item[\(index)] dropped: \(violations.joined(separator: "; "))")
      }
    }
    guard !valid.isEmpty else {
      throw GatewayError.extraction(
        message: extracted.isEmpty
          ? "Strategy produced no items"
          : "All \(extracted.count) extracted items failed schema validation: \(warnings.joined(separator: " | "))"
      )
    }
    return ExecutionResult(items: Array(valid.prefix(count)), warnings: warnings, backendUsed: backendUsed)
  }

  /// Acquires content by walking the strategy's backend chain in order.
  public func acquire(strategy: Strategy, count: Int) async throws -> (ScrapedContent, BackendName) {
    let request = ScrapeRequest(
      url: strategy.acquisition.resolvedURL(count: count),
      renderJS: strategy.acquisition.renderJS,
      headers: strategy.acquisition.headers ?? [:],
      format: strategy.acquisition.format
    )
    var failures: [String] = []
    for name in strategy.backends {
      do {
        let backend = try backends.backend(named: name)
        let content = try await backend.fetch(request)
        guard !content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          failures.append("\(name.rawValue): empty body")
          continue
        }
        return (content, name)
      } catch {
        failures.append("\(name.rawValue): \(error)")
      }
    }
    throw GatewayError.extraction(
      message: "All backends failed for \(request.url): \(failures.joined(separator: " | "))"
    )
  }

  private func extract(strategy: Strategy, content: ScrapedContent, count: Int) async throws -> [JSONValue] {
    switch strategy.extraction {
    case .rss(let spec):
      return try RSSExtractor.extract(from: content.body, spec: spec, count: count)
    case .css(let spec):
      return try CSSExtractor.extract(from: content.body, pageURL: content.url, spec: spec, count: count)
    case .json(let spec):
      return try JSONExtractor.extract(from: content.body, spec: spec, count: count)
    case .llm(let spec):
      return try await extractWithLLM(strategy: strategy, spec: spec, content: content, count: count)
    }
  }

  private func extractWithLLM(
    strategy: Strategy,
    spec: LLMExtraction,
    content: ScrapedContent,
    count: Int
  ) async throws -> [JSONValue] {
    guard let llm else {
      throw GatewayError.configuration(message: "Strategy uses llm extraction but no LLM client is configured")
    }
    let schemaText = try strategy.outputSchema.encodedString()
    let body = String(content.body.prefix(contentMaxChars))
    let prompt = """
    Extract the latest \(count) items from the following page content.

    Page URL: \(content.url)
    Instructions: \(spec.instructions)

    Each item must be a JSON object conforming to this JSON Schema:
    \(schemaText)

    Respond with ONLY a JSON array of item objects, newest first. No prose.

    PAGE CONTENT:
    \(body)
    """
    let completion = try await llm.complete(
      LLMRequest(system: "You extract structured news items from web content. Output strict JSON only.", prompt: prompt)
    )
    let payload = try LLMJSONPayload.extract(from: completion)
    guard let array = payload.arrayValue else {
      throw GatewayError.extraction(message: "LLM extraction did not return a JSON array")
    }
    return array
  }
}
