import Foundation
import SwiftSoup

/// Extracts items from HTML using CSS selectors (SwiftSoup).
public enum CSSExtractor {
  public static func extract(
    from html: String,
    pageURL: String,
    spec: CSSExtraction,
    count: Int
  ) throws -> [JSONValue] {
    let document: Document
    do {
      document = try SwiftSoup.parse(html, pageURL)
    } catch {
      throw GatewayError.extraction(message: "HTML parse failed: \(error)")
    }

    let elements: Elements
    do {
      elements = try document.select(spec.itemSelector)
    } catch {
      throw GatewayError.extraction(message: "Invalid item selector \"\(spec.itemSelector)\": \(error)")
    }

    var items: [JSONValue] = []
    for element in elements.array().prefix(count) {
      var object: [String: JSONValue] = [:]
      for (field, rule) in spec.fields {
        if let value = try? value(of: rule, in: element, pageURL: pageURL), !value.isEmpty {
          object[field] = .string(value)
        }
      }
      if !object.isEmpty {
        items.append(.object(object))
      }
    }
    return items
  }

  private static func value(of rule: CSSExtraction.FieldRule, in element: Element, pageURL: String) throws -> String? {
    let target: Element?
    if let selector = rule.selector, !selector.isEmpty {
      target = try element.select(selector).first()
    } else {
      target = element
    }
    guard let target else { return nil }

    var raw: String
    if let attribute = rule.attribute, !attribute.isEmpty {
      raw = try target.attr(attribute)
    } else {
      raw = try target.text()
    }
    raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }

    if rule.resolveURL == true {
      if let base = URL(string: pageURL), let resolved = URL(string: raw, relativeTo: base) {
        return resolved.absoluteString
      }
    }
    return raw
  }
}
