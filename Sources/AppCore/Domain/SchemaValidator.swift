import Foundation

/// Minimal JSON Schema (subset) validator used to check fetched items against
/// a strategy's output schema. Supported keywords: `type` (string or array of
/// strings), `required`, `properties`, `items`, `enum` (strings).
public enum SchemaValidator {
  /// Returns human-readable violation messages; empty means valid.
  public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
    guard let schemaObject = schema.objectValue else {
      return []
    }

    var errors: [String] = []

    if let typeSpec = schemaObject["type"] {
      let allowed: [String]
      switch typeSpec {
      case .string(let single):
        allowed = [single]
      case .array(let list):
        allowed = list.compactMap(\.stringValue)
      default:
        allowed = []
      }
      if !allowed.isEmpty, !allowed.contains(where: { matches(value, type: $0) }) {
        errors.append("\(path): expected type \(allowed.joined(separator: "|")), got \(typeName(of: value))")
      }
    }

    if let enumSpec = schemaObject["enum"]?.arrayValue {
      if !enumSpec.contains(value) {
        errors.append("\(path): value not in enum")
      }
    }

    if let object = value.objectValue {
      if let required = schemaObject["required"]?.arrayValue {
        for name in required.compactMap(\.stringValue) where object[name] == nil || object[name] == .null {
          errors.append("\(path): missing required property \"\(name)\"")
        }
      }
      if let properties = schemaObject["properties"]?.objectValue {
        for (name, propertySchema) in properties {
          if let propertyValue = object[name] {
            errors.append(contentsOf: validate(propertyValue, against: propertySchema, path: "\(path).\(name)"))
          }
        }
      }
    }

    if let array = value.arrayValue, let itemSchema = schemaObject["items"] {
      for (index, element) in array.enumerated() {
        errors.append(contentsOf: validate(element, against: itemSchema, path: "\(path)[\(index)]"))
      }
    }

    return errors
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch type {
    case "null": return value.isNull
    case "boolean": return value.boolValue != nil
    case "string": return value.stringValue != nil
    case "number": return value.numberValue != nil
    case "integer":
      guard let number = value.numberValue else { return false }
      return number == number.rounded()
    case "array": return value.arrayValue != nil
    case "object": return value.objectValue != nil
    default: return true
    }
  }

  private static func typeName(of value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "boolean"
    case .number: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }
}
