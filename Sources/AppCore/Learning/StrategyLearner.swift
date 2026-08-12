import Foundation

/// What the LLM proposes; converted into a Strategy after validation.
public struct StrategyProposal: Codable, Sendable, Equatable {
  public var name: String
  public var notes: String?
  public var backends: [BackendName]?
  public var acquisition: AcquisitionSpec
  public var extraction: ExtractionSpec
  public var outputSchema: JSONValue?

  public init(
    name: String,
    notes: String? = nil,
    backends: [BackendName]? = nil,
    acquisition: AcquisitionSpec,
    extraction: ExtractionSpec,
    outputSchema: JSONValue? = nil
  ) {
    self.name = name
    self.notes = notes
    self.backends = backends
    self.acquisition = acquisition
    self.extraction = extraction
    self.outputSchema = outputSchema
  }
}

/// Inputs for one learning run.
public struct LearningRequest: Sendable {
  public var sourceURL: String
  public var count: Int
  public var hints: String?
  /// Caller-required item schema; when nil the LLM proposes one.
  public var requiredSchema: JSONValue?
  /// Existing strategy being updated (id and version are preserved/bumped).
  public var existing: Strategy?
  /// Failure feedback from a previous execution, used for re-learning.
  public var feedback: String?

  public init(
    sourceURL: String,
    count: Int,
    hints: String? = nil,
    requiredSchema: JSONValue? = nil,
    existing: Strategy? = nil,
    feedback: String? = nil
  ) {
    self.sourceURL = sourceURL
    self.count = count
    self.hints = hints
    self.requiredSchema = requiredSchema
    self.existing = existing
    self.feedback = feedback
  }
}

/// Learns a fetch strategy for a URL: sample the page, ask the LLM to
/// propose a strategy document, execute the proposal against the live
/// source, and repair with error feedback until it works (bounded rounds).
public struct StrategyLearner: Sendable {
  private let llm: any LLMClient
  private let executor: StrategyExecutor
  private let defaultBackends: [BackendName]
  private let defaultRetry: RetryPolicyConfig
  private let maxRounds: Int
  private let contentMaxChars: Int
  private let now: @Sendable () -> Date
  private let makeID: @Sendable () -> String

  public init(
    llm: any LLMClient,
    executor: StrategyExecutor,
    defaultBackends: [BackendName],
    defaultRetry: RetryPolicyConfig = .default,
    maxRounds: Int = 3,
    contentMaxChars: Int = 60_000,
    now: @escaping @Sendable () -> Date = { Date() },
    makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.llm = llm
    self.executor = executor
    self.defaultBackends = defaultBackends
    self.defaultRetry = defaultRetry
    self.maxRounds = maxRounds
    self.contentMaxChars = contentMaxChars
    self.now = now
    self.makeID = makeID
  }

  public func learn(_ request: LearningRequest) async throws -> Strategy {
    let sourceURL = try SourceURLNormalizer.normalize(request.sourceURL)
    let sample = try await sampleContent(sourceURL: sourceURL, existing: request.existing, count: request.count)
    let discoveredFeeds = await discoverFeeds(from: sample, existing: request.existing, count: request.count)

    var failures: [String] = []
    if let feedback = request.feedback {
      failures.append("Previous strategy failed: \(feedback)")
    }

    for _ in 1...max(1, maxRounds) {
      let prompt = LearningPrompt.build(
        sourceURL: sourceURL,
        count: request.count,
        sample: sample,
        discoveredFeeds: discoveredFeeds,
        hints: request.hints,
        requiredSchema: request.requiredSchema,
        existing: request.existing,
        failures: failures,
        contentMaxChars: contentMaxChars
      )
      let completion: String
      do {
        completion = try await llm.complete(LLMRequest(system: LearningPrompt.system, prompt: prompt))
      } catch {
        throw GatewayError.learningFailed(sourceURL: sourceURL, message: "LLM call failed: \(error)")
      }

      let candidate: Strategy
      do {
        let proposal = try decodeProposal(from: completion)
        candidate = try buildStrategy(from: proposal, request: request, sourceURL: sourceURL)
      } catch {
        failures.append("Proposal was invalid: \(error)")
        continue
      }

      do {
        let result = try await executor.executeOnce(strategy: candidate, count: request.count)
        guard !result.items.isEmpty else {
          failures.append("Strategy executed but produced no items")
          continue
        }
        return candidate
      } catch {
        failures.append("Execution failed: \(error)")
      }
    }

    throw GatewayError.learningFailed(
      sourceURL: sourceURL,
      message: "No working strategy after \(maxRounds) round(s). \(failures.suffix(3).joined(separator: " | "))"
    )
  }

  private func sampleContent(sourceURL: String, existing: Strategy?, count: Int) async throws -> ScrapedContent {
    // Sample the raw source page so the LLM sees the actual structure. Use
    // the existing strategy's backend order when updating, defaults otherwise.
    do {
      return try await fetchSample(
        url: sourceURL,
        backends: existing?.backends ?? defaultBackends,
        renderJS: existing?.acquisition.renderJS ?? false,
        count: count
      )
    } catch {
      throw GatewayError.learningFailed(sourceURL: sourceURL, message: "Could not fetch sample content: \(error)")
    }
  }

  /// Samples feeds advertised by the page so the learner can propose the
  /// (far more reliable) feed-based strategy with evidence.
  private func discoverFeeds(
    from sample: ScrapedContent,
    existing: Strategy?,
    count: Int
  ) async -> [LearningPrompt.DiscoveredFeed] {
    guard FeedAutodiscovery.looksLikeHTMLPage(sample.body) else { return [] }
    let urls = FeedAutodiscovery.feedURLs(inHTML: sample.body, pageURL: sample.url).prefix(2)
    var feeds: [LearningPrompt.DiscoveredFeed] = []
    for url in urls {
      guard
        let content = try? await fetchSample(
          url: url,
          backends: existing?.backends ?? defaultBackends,
          renderJS: false,
          count: count
        )
      else { continue }
      feeds.append(LearningPrompt.DiscoveredFeed(url: url, sample: content.body))
    }
    return feeds
  }

  private func fetchSample(url: String, backends: [BackendName], renderJS: Bool, count: Int) async throws -> ScrapedContent {
    let sampling = Strategy(
      id: "sampling",
      sourceURL: url,
      name: "sampling",
      backends: backends,
      acquisition: AcquisitionSpec(url: url, format: .html, renderJS: renderJS),
      extraction: .rss(RSSExtraction()),
      outputSchema: .object([:]),
      createdAt: now(),
      updatedAt: now()
    )
    let (content, _) = try await executor.acquire(strategy: sampling, count: count)
    return content
  }

  private func decodeProposal(from completion: String) throws -> StrategyProposal {
    let payload = try LLMJSONPayload.extract(from: completion)
    let data = try payload.encodedData()
    return try JSONCoding.decoder.decode(StrategyProposal.self, from: data)
  }

  private func buildStrategy(from proposal: StrategyProposal, request: LearningRequest, sourceURL: String) throws -> Strategy {
    let schema: JSONValue
    if let required = request.requiredSchema {
      schema = required
    } else if let proposed = proposal.outputSchema, proposed.objectValue?.isEmpty == false {
      schema = proposed
    } else {
      throw GatewayError.learningFailed(sourceURL: sourceURL, message: "Proposal contained no output schema")
    }

    let timestamp = now()
    if let existing = request.existing {
      var updated = existing
      updated.name = proposal.name
      updated.notes = proposal.notes ?? existing.notes
      updated.backends = proposal.backends ?? existing.backends
      updated.acquisition = proposal.acquisition
      updated.extraction = proposal.extraction
      updated.outputSchema = schema
      updated.version = existing.version + 1
      updated.updatedAt = timestamp
      return updated
    }
    return Strategy(
      id: makeID(),
      sourceURL: sourceURL,
      name: proposal.name,
      notes: proposal.notes,
      backends: proposal.backends ?? defaultBackends,
      acquisition: proposal.acquisition,
      extraction: proposal.extraction,
      outputSchema: schema,
      retry: defaultRetry,
      version: 1,
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }
}
