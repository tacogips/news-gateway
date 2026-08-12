import Foundation

/// Extracts items from a JSON document using minimal path expressions.
public enum JSONExtractor {
  public static func extract(from body: String, spec: JSONExtraction, count: Int) throws -> [JSONValue] {
    let document: JSONValue
    do {
      document = try JSONValue(parsing: body)
    } catch {
      throw GatewayError.extraction(message: "JSON parse failed: \(error)")
    }

    let itemsPath = try JSONPathExpression(spec.itemsPath)
    guard let itemsValue = itemsPath.evaluate(on: document), let array = itemsValue.arrayValue else {
      throw GatewayError.extraction(message: "Items path \"\(spec.itemsPath)\" did not resolve to an array")
    }

    var fieldPaths: [String: JSONPathExpression] = [:]
    for (field, path) in spec.fields {
      fieldPaths[field] = try JSONPathExpression(path)
    }

    return try array.prefix(count).map { element in
      if fieldPaths.isEmpty {
        return element
      }
      var object: [String: JSONValue] = [:]
      for (field, path) in fieldPaths {
        if let value = path.evaluate(on: element), !value.isNull {
          object[field] = value
        }
      }
      guard !object.isEmpty else {
        throw GatewayError.extraction(message: "No mapped fields resolved for an item")
      }
      return .object(object)
    }
  }
}
