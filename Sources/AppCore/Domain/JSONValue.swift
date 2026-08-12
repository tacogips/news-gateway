import Foundation

/// Arbitrary JSON value used for strategy output schemas and fetched items.
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Value is not valid JSON"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

extension JSONValue {
  public init(parsing data: Data) throws {
    self = try JSONCoding.decoder.decode(JSONValue.self, from: data)
  }

  public init(parsing text: String) throws {
    try self.init(parsing: Data(text.utf8))
  }

  public func encodedData(pretty: Bool = false) throws -> Data {
    let encoder = pretty ? JSONCoding.prettyEncoder : JSONCoding.encoder
    return try encoder.encode(self)
  }

  public func encodedString(pretty: Bool = false) throws -> String {
    String(decoding: try encodedData(pretty: pretty), as: UTF8.self)
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  public subscript(index: Int) -> JSONValue? {
    guard let array = arrayValue, array.indices.contains(index) else { return nil }
    return array[index]
  }
}

/// Shared JSON coders with stable settings (ISO 8601 dates, sorted keys).
public enum JSONCoding {
  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static var prettyEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
