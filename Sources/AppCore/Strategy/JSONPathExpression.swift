import Foundation

/// Minimal path language for JSONExtraction: dot-separated object keys with
/// optional numeric indexes, e.g. `data.articles`, `items[0].title`.
/// A leading `$.` or `$` refers to the root; an empty path is the identity.
public struct JSONPathExpression: Sendable, Equatable {
  enum Component: Equatable {
    case key(String)
    case index(Int)
  }

  let components: [Component]

  public init(_ path: String) throws {
    var text = path.trimmingCharacters(in: .whitespaces)
    if text == "$" || text.isEmpty {
      components = []
      return
    }
    if text.hasPrefix("$.") {
      text = String(text.dropFirst(2))
    } else if text.hasPrefix("$") {
      text = String(text.dropFirst(1))
    }

    var parsed: [Component] = []
    for segment in text.split(separator: ".", omittingEmptySubsequences: false) {
      var rest = Substring(segment)
      guard !rest.isEmpty else {
        throw GatewayError.invalidInput(message: "Empty path segment in \"\(path)\"")
      }
      if let bracket = rest.firstIndex(of: "[") {
        let key = rest[..<bracket]
        if !key.isEmpty {
          parsed.append(.key(String(key)))
        }
        rest = rest[bracket...]
        while rest.hasPrefix("[") {
          guard let close = rest.firstIndex(of: "]") else {
            throw GatewayError.invalidInput(message: "Unclosed index in \"\(path)\"")
          }
          let inside = rest[rest.index(after: rest.startIndex)..<close]
          guard let index = Int(inside) else {
            throw GatewayError.invalidInput(message: "Non-numeric index \"\(inside)\" in \"\(path)\"")
          }
          parsed.append(.index(index))
          rest = rest[rest.index(after: close)...]
        }
        guard rest.isEmpty else {
          throw GatewayError.invalidInput(message: "Trailing characters after index in \"\(path)\"")
        }
      } else {
        parsed.append(.key(String(rest)))
      }
    }
    components = parsed
  }

  public func evaluate(on value: JSONValue) -> JSONValue? {
    var current = value
    for component in components {
      switch component {
      case .key(let key):
        guard let next = current[key] else { return nil }
        current = next
      case .index(let index):
        guard let next = current[index] else { return nil }
        current = next
      }
    }
    return current
  }
}
