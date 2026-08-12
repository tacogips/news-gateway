import Foundation

/// How items are extracted from acquired content. Serialized as a
/// discriminated union with a `kind` field so LLM-proposed strategies are
/// easy to author and validate.
public enum ExtractionSpec: Sendable, Equatable {
  case rss(RSSExtraction)
  case css(CSSExtraction)
  case json(JSONExtraction)
  case llm(LLMExtraction)
}

/// RSS/Atom feed extraction. Feed entry fields: `title`, `link`,
/// `published`, `summary`, `id`, `author`. `fieldMap` maps output schema
/// field names to feed entry fields; empty uses a standard mapping.
public struct RSSExtraction: Codable, Sendable, Equatable {
  public var fieldMap: [String: String]

  public init(fieldMap: [String: String] = [:]) {
    self.fieldMap = fieldMap
  }
}

/// CSS selector extraction over HTML.
public struct CSSExtraction: Codable, Sendable, Equatable {
  public struct FieldRule: Codable, Sendable, Equatable {
    /// Selector relative to the item element; nil targets the item itself.
    public var selector: String?
    /// Attribute to read (e.g. "href", "src", "datetime"); nil reads text.
    public var attribute: String?
    /// Resolve the value as a URL relative to the page URL.
    public var resolveURL: Bool?

    public init(selector: String? = nil, attribute: String? = nil, resolveURL: Bool? = nil) {
      self.selector = selector
      self.attribute = attribute
      self.resolveURL = resolveURL
    }
  }

  /// Selector matching one element per item, in page order (newest first).
  public var itemSelector: String
  /// Output schema field name -> rule.
  public var fields: [String: FieldRule]

  public init(itemSelector: String, fields: [String: FieldRule]) {
    self.itemSelector = itemSelector
    self.fields = fields
  }
}

/// JSON API extraction using minimal dot/index paths (see JSONPathExpression).
public struct JSONExtraction: Codable, Sendable, Equatable {
  /// Path from the document root to the array of items.
  public var itemsPath: String
  /// Output schema field name -> path relative to one item.
  public var fields: [String: String]

  public init(itemsPath: String, fields: [String: String]) {
    self.itemsPath = itemsPath
    self.fields = fields
  }
}

/// Per-fetch LLM extraction; the fallback when no deterministic rule works.
public struct LLMExtraction: Codable, Sendable, Equatable {
  public var instructions: String

  public init(instructions: String) {
    self.instructions = instructions
  }
}

extension ExtractionSpec: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case rss
    case css
    case json
    case llm
  }

  private enum Kind: String, Codable {
    case rss
    case css
    case json
    case llm
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .rss:
      self = .rss(try container.decodeIfPresent(RSSExtraction.self, forKey: .rss) ?? RSSExtraction())
    case .css:
      self = .css(try container.decode(CSSExtraction.self, forKey: .css))
    case .json:
      self = .json(try container.decode(JSONExtraction.self, forKey: .json))
    case .llm:
      self = .llm(try container.decode(LLMExtraction.self, forKey: .llm))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .rss(let spec):
      try container.encode(Kind.rss, forKey: .kind)
      try container.encode(spec, forKey: .rss)
    case .css(let spec):
      try container.encode(Kind.css, forKey: .kind)
      try container.encode(spec, forKey: .css)
    case .json(let spec):
      try container.encode(Kind.json, forKey: .kind)
      try container.encode(spec, forKey: .json)
    case .llm(let spec):
      try container.encode(Kind.llm, forKey: .kind)
      try container.encode(spec, forKey: .llm)
    }
  }

  public var kindName: String {
    switch self {
    case .rss: return "rss"
    case .css: return "css"
    case .json: return "json"
    case .llm: return "llm"
    }
  }
}
