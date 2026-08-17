import Foundation

/// The library facade. Owns the store, backends, learner, and retry policy.
/// The CLI and (later) riela nodes are thin wrappers over this actor.
public actor WebGateway {
  private let store: any StrategyStore
  private let executor: StrategyExecutor
  private let learner: StrategyLearner
  private let sleeper: any Sleeper
  private let now: @Sendable () -> Date

  /// Builds a gateway from config plus injectable effects (tests pass fakes).
  public init(
    config: GatewayConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    dbPathOverride: String? = nil,
    transport: (any HTTPTransport)? = nil,
    processRunner: (any ProcessRunner)? = nil,
    llm: (any LLMClient)? = nil,
    store: (any StrategyStore)? = nil,
    sleeper: any Sleeper = TaskSleeper(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws {
    let transport = transport ?? URLSessionTransport()
    let runner = processRunner ?? FoundationProcessRunner()

    let registry = Self.buildRegistry(
      config: config,
      environment: environment,
      transport: transport,
      runner: runner
    )
    let llmClient = llm ?? Self.buildLLMClient(config: config.llm, environment: environment, transport: transport, runner: runner)
    let executor = StrategyExecutor(
      backends: registry,
      llm: llmClient,
      contentMaxChars: config.learning.contentMaxChars
    )

    self.store = try store ?? SQLiteStrategyStore(
      path: config.resolvedDBPath(override: dbPathOverride, environment: environment)
    )
    self.executor = executor
    self.learner = StrategyLearner(
      llm: llmClient,
      executor: executor,
      defaultBackends: config.defaultBackends,
      defaultRetry: config.defaultRetry,
      maxRounds: config.learning.maxRounds,
      contentMaxChars: config.learning.contentMaxChars,
      now: now
    )
    self.sleeper = sleeper
    self.now = now
  }

  // MARK: - Fetch

  public func fetchLatest(
    url: String,
    count: Int = 20,
    learnIfMissing: Bool = false,
    relearnOnFailure: Bool = false,
    maxAttempts: Int? = nil
  ) async throws -> FetchOutput {
    let sourceURL = try SourceURLNormalizer.normalize(url)

    let strategy: Strategy
    if let stored = try await store.find(sourceURL: sourceURL) {
      strategy = stored.strategy
    } else if learnIfMissing {
      strategy = try await learner.learn(LearningRequest(sourceURL: sourceURL, count: count))
      try await store.save(strategy)
    } else {
      throw GatewayError.noStrategy(sourceURL: sourceURL)
    }

    var retryConfig = strategy.retry
    if let maxAttempts {
      retryConfig.maxAttempts = maxAttempts
    }

    do {
      let (result, _) = try await Backoff.withRetry(config: retryConfig, sleeper: sleeper) { [executor] _ in
        try await executor.executeOnce(strategy: strategy, count: count)
      }
      try await store.recordOutcome(id: strategy.id, success: true, error: nil, at: now())
      return output(for: strategy, result: result)
    } catch let exhausted as Backoff.RetryExhausted {
      let message = String(describing: exhausted.lastError)
      try? await store.recordOutcome(id: strategy.id, success: false, error: message, at: now())

      guard relearnOnFailure else {
        throw GatewayError.fetchFailed(sourceURL: sourceURL, attempts: exhausted.attempts, message: message)
      }

      let relearned = try await learner.learn(
        LearningRequest(sourceURL: sourceURL, count: count, existing: strategy, feedback: message)
      )
      try await store.save(relearned)
      do {
        let result = try await executor.executeOnce(strategy: relearned, count: count)
        try await store.recordOutcome(id: relearned.id, success: true, error: nil, at: now())
        return output(for: relearned, result: result)
      } catch {
        let finalMessage = "\(message); after re-learning: \(error)"
        try? await store.recordOutcome(id: relearned.id, success: false, error: finalMessage, at: now())
        throw GatewayError.fetchFailed(sourceURL: sourceURL, attempts: exhausted.attempts + 1, message: finalMessage)
      }
    }
  }

  // MARK: - Strategy management

  /// Learns (or re-learns, when a strategy for the URL exists) and persists.
  public func learnStrategy(
    url: String,
    count: Int = 20,
    hints: String? = nil,
    outputSchema: JSONValue? = nil
  ) async throws -> Strategy {
    let sourceURL = try SourceURLNormalizer.normalize(url)
    let existing = try await store.find(sourceURL: sourceURL)
    let strategy = try await learner.learn(
      LearningRequest(
        sourceURL: sourceURL,
        count: count,
        hints: hints,
        requiredSchema: outputSchema,
        existing: existing?.strategy
      )
    )
    try await store.save(strategy)
    return strategy
  }

  /// Re-learns an existing strategy by id or source URL (version + 1).
  public func updateStrategy(
    idOrURL: String,
    count: Int = 20,
    hints: String? = nil,
    outputSchema: JSONValue? = nil
  ) async throws -> Strategy {
    guard let stored = try await store.findByIDOrURL(idOrURL) else {
      throw GatewayError.noStrategy(sourceURL: idOrURL)
    }
    let existing = stored.strategy
    let strategy = try await learner.learn(
      LearningRequest(
        sourceURL: existing.sourceURL,
        count: count,
        hints: hints,
        requiredSchema: outputSchema,
        existing: existing
      )
    )
    try await store.save(strategy)
    return strategy
  }

  public func strategies() async throws -> [StoredStrategy] {
    try await store.list()
  }

  public func strategy(idOrURL: String) async throws -> StoredStrategy? {
    try await store.findByIDOrURL(idOrURL)
  }

  public func deleteStrategy(idOrURL: String) async throws -> Bool {
    try await store.delete(idOrURL: idOrURL)
  }

  // MARK: - Helpers

  private func output(for strategy: Strategy, result: ExecutionResult) -> FetchOutput {
    FetchOutput(
      sourceURL: strategy.sourceURL,
      strategyID: strategy.id,
      strategyVersion: strategy.version,
      fetchedAt: now(),
      backendUsed: result.backendUsed.rawValue,
      items: result.items,
      warnings: result.warnings
    )
  }

  private static func buildRegistry(
    config: GatewayConfig,
    environment: [String: String],
    transport: any HTTPTransport,
    runner: any ProcessRunner
  ) -> BackendRegistry {
    var backends: [any ScrapingBackend] = [HTTPScrapingBackend(transport: transport)]

    let firecrawlEnv = config.firecrawl?.apiKeyEnv ?? "FIRECRAWL_API_KEY"
    if let key = environment[firecrawlEnv], !key.isEmpty {
      backends.append(
        FirecrawlBackend(
          transport: transport,
          apiKey: key,
          baseURL: config.firecrawl?.baseURL ?? "https://api.firecrawl.dev"
        )
      )
    }

    let zenrowsEnv = config.zenrows?.apiKeyEnv ?? "ZENROWS_API_KEY"
    if let key = environment[zenrowsEnv], !key.isEmpty {
      backends.append(
        ZenRowsBackend(
          transport: transport,
          apiKey: key,
          baseURL: config.zenrows?.baseURL ?? "https://api.zenrows.com"
        )
      )
    }

    if let playwright = config.playwright, !playwright.command.isEmpty {
      backends.append(
        PlaywrightCommandBackend(
          runner: runner,
          commandTemplate: playwright.command,
          timeoutSeconds: playwright.timeoutSeconds ?? 120
        )
      )
    }

    let kitesurfAccountEnv = config.kitesurf?.accountIDEnv ?? "CLOUDFLARE_ACCOUNT_ID"
    let kitesurfTokenEnv = config.kitesurf?.apiTokenEnv ?? "CLOUDFLARE_API_TOKEN"
    if let accountID = environment[kitesurfAccountEnv], !accountID.isEmpty,
       let apiToken = environment[kitesurfTokenEnv], !apiToken.isEmpty {
      backends.append(
        KitesurfBackend(
          transport: transport,
          accountID: accountID,
          apiToken: apiToken,
          baseURL: config.kitesurf?.baseURL ?? "https://api.cloudflare.com/client/v4"
        )
      )
    }

    if let agentBrowser = config.agentBrowser, !agentBrowser.command.isEmpty {
      backends.append(
        AgentBrowserBackend(
          runner: runner,
          command: agentBrowser.command,
          timeoutSeconds: agentBrowser.timeoutSeconds ?? 120
        )
      )
    }

    return BackendRegistry(backends: backends)
  }

  private static func buildLLMClient(
    config: GatewayConfig.LLMConfig,
    environment: [String: String],
    transport: any HTTPTransport,
    runner: any ProcessRunner
  ) -> any LLMClient {
    switch config.mode {
    case .acp:
      guard let vendor = config.vendor, let model = config.model else {
        return FailingLLMClient(
          error: GatewayError.configuration(
            message: "llm is not configured: set llm.vendor and llm.model (mode acp) in the config file"
          )
        )
      }
      return ACPAgentGatewayLLMClient(
        options: ACPAgentGatewayLLMClient.Options(
          vendor: vendor,
          model: model,
          apiKeyEnvironment: config.apiKeyEnv,
          baseURL: config.baseURL,
          providerName: config.providerName,
          maxTokens: config.maxTokens
        )
      )
    case .command:
      return AgentGatewayLLMClient(
        mode: .command(config.command ?? ["agent-gateway"]),
        runner: runner,
        transport: transport
      )
    case .http:
      guard let endpoint = config.endpoint, let model = config.model else {
        return FailingLLMClient(
          error: GatewayError.configuration(message: "llm.mode is http but endpoint/model are not set")
        )
      }
      let apiKey = config.apiKeyEnv.flatMap { environment[$0] }
      return AgentGatewayLLMClient(
        mode: .http(endpoint: endpoint, model: model, apiKey: apiKey),
        runner: runner,
        transport: transport
      )
    }
  }
}

/// Surfaces a configuration error at first LLM use instead of at startup, so
/// deterministic fetches keep working with a broken LLM config.
struct FailingLLMClient: LLMClient {
  let error: GatewayError

  func complete(_ request: LLMRequest) async throws -> String {
    throw error
  }
}
