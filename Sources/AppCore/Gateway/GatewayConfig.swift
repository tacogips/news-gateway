import Foundation

/// Configuration for the gateway. Loaded from a JSON file plus environment;
/// secrets are only ever referenced by environment variable name.
public struct GatewayConfig: Codable, Sendable, Equatable {
  public struct FirecrawlConfig: Codable, Sendable, Equatable {
    public var apiKeyEnv: String?
    public var baseURL: String?

    public init(apiKeyEnv: String? = nil, baseURL: String? = nil) {
      self.apiKeyEnv = apiKeyEnv
      self.baseURL = baseURL
    }
  }

  public struct ZenRowsConfig: Codable, Sendable, Equatable {
    public var apiKeyEnv: String?
    public var baseURL: String?

    public init(apiKeyEnv: String? = nil, baseURL: String? = nil) {
      self.apiKeyEnv = apiKeyEnv
      self.baseURL = baseURL
    }
  }

  public struct PlaywrightConfig: Codable, Sendable, Equatable {
    /// Command template printing rendered HTML to stdout; {url} is replaced.
    public var command: [String]
    public var timeoutSeconds: Int?

    public init(command: [String], timeoutSeconds: Int? = nil) {
      self.command = command
      self.timeoutSeconds = timeoutSeconds
    }
  }

  public enum LLMMode: String, Codable, Sendable {
    /// agent-gateway hosted in-process over ACP (default).
    case acp
    /// Spawn an argv; prompt on stdin, completion on stdout.
    case command
    /// OpenAI-compatible chat/completions endpoint.
    case http
  }

  public struct LLMConfig: Codable, Sendable, Equatable {
    public var mode: LLMMode
    /// acp mode: agent-gateway vendor (anthropic, openai, gemini,
    /// openrouter, claude-code, codex, cursor, cursor-api).
    public var vendor: String?
    /// acp/http mode: model identifier.
    public var model: String?
    /// Environment variable NAME holding the API key (never the key itself).
    public var apiKeyEnv: String?
    /// acp mode: custom provider base URL / named routing provider.
    public var baseURL: String?
    public var providerName: String?
    public var maxTokens: Int?
    /// command mode: argv to spawn.
    public var command: [String]?
    /// http mode: endpoint URL.
    public var endpoint: String?

    public init(
      mode: LLMMode = .acp,
      vendor: String? = nil,
      model: String? = nil,
      apiKeyEnv: String? = nil,
      baseURL: String? = nil,
      providerName: String? = nil,
      maxTokens: Int? = nil,
      command: [String]? = nil,
      endpoint: String? = nil
    ) {
      self.mode = mode
      self.vendor = vendor
      self.model = model
      self.apiKeyEnv = apiKeyEnv
      self.baseURL = baseURL
      self.providerName = providerName
      self.maxTokens = maxTokens
      self.command = command
      self.endpoint = endpoint
    }
  }

  public struct LearningConfig: Codable, Sendable, Equatable {
    public var maxRounds: Int
    public var contentMaxChars: Int

    public init(maxRounds: Int = 3, contentMaxChars: Int = 60_000) {
      self.maxRounds = maxRounds
      self.contentMaxChars = contentMaxChars
    }
  }

  public var dbPath: String?
  public var defaultBackends: [BackendName]
  public var defaultRetry: RetryPolicyConfig
  public var firecrawl: FirecrawlConfig?
  public var zenrows: ZenRowsConfig?
  public var playwright: PlaywrightConfig?
  public var llm: LLMConfig
  public var learning: LearningConfig

  public init(
    dbPath: String? = nil,
    defaultBackends: [BackendName] = [.http],
    defaultRetry: RetryPolicyConfig = .default,
    firecrawl: FirecrawlConfig? = nil,
    zenrows: ZenRowsConfig? = nil,
    playwright: PlaywrightConfig? = nil,
    llm: LLMConfig = LLMConfig(),
    learning: LearningConfig = LearningConfig()
  ) {
    self.dbPath = dbPath
    self.defaultBackends = defaultBackends
    self.defaultRetry = defaultRetry
    self.firecrawl = firecrawl
    self.zenrows = zenrows
    self.playwright = playwright
    self.llm = llm
    self.learning = learning
  }

  /// Missing keys fall back to defaults so partial config files are valid.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dbPath = try container.decodeIfPresent(String.self, forKey: .dbPath)
    defaultBackends = try container.decodeIfPresent([BackendName].self, forKey: .defaultBackends) ?? [.http]
    defaultRetry = try container.decodeIfPresent(RetryPolicyConfig.self, forKey: .defaultRetry) ?? .default
    firecrawl = try container.decodeIfPresent(FirecrawlConfig.self, forKey: .firecrawl)
    zenrows = try container.decodeIfPresent(ZenRowsConfig.self, forKey: .zenrows)
    playwright = try container.decodeIfPresent(PlaywrightConfig.self, forKey: .playwright)
    llm = try container.decodeIfPresent(LLMConfig.self, forKey: .llm) ?? LLMConfig()
    learning = try container.decodeIfPresent(LearningConfig.self, forKey: .learning) ?? LearningConfig()
  }

  public static let `default` = GatewayConfig()

  public static let defaultConfigPath = "~/.config/news-gateway/config.json"
  public static let defaultDBPath = "~/.local/share/news-gateway/news-gateway.sqlite3"

  /// Loads config from `path` (or the default location). A missing file at
  /// the default location falls back to defaults; a missing explicit path is
  /// an error.
  public static func load(path: String?, environment: [String: String]) throws -> GatewayConfig {
    let explicit = path ?? environment["NEWS_GATEWAY_CONFIG"]
    let candidate = expand(explicit ?? defaultConfigPath)
    guard FileManager.default.fileExists(atPath: candidate) else {
      if explicit != nil {
        throw GatewayError.configuration(message: "Config file not found: \(candidate)")
      }
      return .default
    }
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: candidate))
      return try JSONCoding.decoder.decode(GatewayConfig.self, from: data)
    } catch let error as GatewayError {
      throw error
    } catch {
      throw GatewayError.configuration(message: "Could not parse \(candidate): \(error)")
    }
  }

  /// Effective database path after overrides (argument > env > config > default).
  public func resolvedDBPath(override: String?, environment: [String: String]) -> String {
    GatewayConfig.expand(override ?? environment["NEWS_GATEWAY_DB"] ?? dbPath ?? GatewayConfig.defaultDBPath)
  }

  public static func expand(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + path.dropFirst(1)
  }

  /// Commented template written by `news-gateway config init`.
  public static let templateJSON = """
  {
    "dbPath": null,
    "defaultBackends": ["http"],
    "defaultRetry": {
      "maxAttempts": 3,
      "initialDelayMs": 500,
      "multiplier": 2.0,
      "maxDelayMs": 15000,
      "jitter": 0.2
    },
    "firecrawl": { "apiKeyEnv": "FIRECRAWL_API_KEY" },
    "zenrows": { "apiKeyEnv": "ZENROWS_API_KEY" },
    "playwright": { "command": ["node", "scripts/playwright-fetch.mjs", "{url}"] },
    "llm": {
      "mode": "acp",
      "vendor": "anthropic",
      "model": "claude-sonnet-5",
      "apiKeyEnv": "ANTHROPIC_API_KEY"
    },
    "learning": { "maxRounds": 3, "contentMaxChars": 60000 }
  }
  """
}
