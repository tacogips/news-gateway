import Foundation
import SwiftSoup

/// Post-processing applied to extracted items before schema validation:
/// date normalization to ISO 8601 UTC, HTML stripping from text fields,
/// deduplication, and newest-first ordering.
public enum ItemNormalizer {
  /// Field names treated as dates when the schema does not mark them with
  /// `"format": "date-time"`.
  static let dateFieldNames: Set<String> = [
    "publishedAt", "published", "updatedAt", "updated", "date", "pubDate", "createdAt"
  ]

  public static func normalize(
    items: [JSONValue],
    schema: JSONValue,
    warnings: inout [String]
  ) -> [JSONValue] {
    let properties = schema["properties"]?.objectValue ?? [:]
    let dateFields = dateFields(in: properties)
    let uriFields = uriFields(in: properties)

    var normalized: [JSONValue] = items.map { item in
      normalizeItem(item, dateFields: dateFields, uriFields: uriFields, warnings: &warnings)
    }
    normalized = deduplicate(normalized, warnings: &warnings)
    normalized = sortNewestFirst(normalized, dateFields: dateFields)
    return normalized
  }

  private static func dateFields(in properties: [String: JSONValue]) -> Set<String> {
    var fields = Set<String>()
    for (name, property) in properties {
      if property["format"]?.stringValue == "date-time" || dateFieldNames.contains(name) {
        fields.insert(name)
      }
    }
    // Conventional date fields count even when absent from the schema.
    fields.formUnion(dateFieldNames)
    return fields
  }

  private static func uriFields(in properties: [String: JSONValue]) -> Set<String> {
    var fields = Set<String>(["url", "link", "id"])
    for (name, property) in properties where property["format"]?.stringValue == "uri" {
      fields.insert(name)
    }
    return fields
  }

  private static func normalizeItem(
    _ item: JSONValue,
    dateFields: Set<String>,
    uriFields: Set<String>,
    warnings: inout [String]
  ) -> JSONValue {
    guard var object = item.objectValue else { return item }
    for (field, value) in object {
      guard let text = value.stringValue else { continue }
      if dateFields.contains(field) {
        if let iso = ItemDateParser.iso8601(from: text) {
          object[field] = .string(iso)
        }
      } else if !uriFields.contains(field), looksLikeHTML(text) {
        let stripped = stripHTML(text)
        if !stripped.isEmpty {
          object[field] = .string(stripped)
        }
      }
    }
    return .object(object)
  }

  static func looksLikeHTML(_ text: String) -> Bool {
    text.contains("</") || text.contains("/>") || text.contains("<p") || text.contains("<a ")
      || text.contains("<br") || text.contains("&lt;") || text.contains("&amp;")
  }

  static func stripHTML(_ html: String) -> String {
    guard let document = try? SwiftSoup.parseBodyFragment(html), let text = try? document.text() else {
      return html
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Removes duplicates by url/link/id (first occurrence wins); items with
  /// no identity fall back to whole-object equality.
  private static func deduplicate(_ items: [JSONValue], warnings: inout [String]) -> [JSONValue] {
    var seen = Set<String>()
    var result: [JSONValue] = []
    var dropped = 0
    for item in items {
      let key = identity(of: item)
      if seen.contains(key) {
        dropped += 1
        continue
      }
      seen.insert(key)
      result.append(item)
    }
    if dropped > 0 {
      warnings.append("dropped \(dropped) duplicate item(s)")
    }
    return result
  }

  private static func identity(of item: JSONValue) -> String {
    for field in ["url", "link", "id"] {
      if let value = item[field]?.stringValue, !value.isEmpty {
        return "\(field):\(value)"
      }
    }
    return (try? item.encodedString()) ?? ""
  }

  /// Sorts newest first, but only when every item carries a parseable date;
  /// otherwise the source order (usually already newest-first) is kept.
  private static func sortNewestFirst(_ items: [JSONValue], dateFields: Set<String>) -> [JSONValue] {
    let dates = items.map { item -> Date? in
      for field in dateFields {
        if let text = item[field]?.stringValue, let date = ItemDateParser.date(from: text) {
          return date
        }
      }
      return nil
    }
    guard items.count > 1, dates.allSatisfy({ $0 != nil }) else { return items }
    return zip(items, dates)
      .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
      .map(\.0)
  }
}

/// Parses the date formats that show up in feeds and websites.
enum ItemDateParser {
  private static func makeOutputFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }

  private static let inputPatterns = [
    "EEE, dd MMM yyyy HH:mm:ss Z",   // RFC 822 / RSS pubDate
    "EEE, dd MMM yyyy HH:mm:ss zzz",
    "dd MMM yyyy HH:mm:ss Z",
    "yyyy-MM-dd HH:mm:ss Z",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy/MM/dd HH:mm:ss",
    "yyyy-MM-dd",
    "yyyy/MM/dd"
  ]

  static func date(from text: String) -> Date? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: trimmed) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) { return date }

    for pattern in inputPatterns {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = pattern
      if let date = formatter.date(from: trimmed) { return date }
    }
    return nil
  }

  /// Returns the ISO 8601 UTC rendering, or nil when unparseable.
  static func iso8601(from text: String) -> String? {
    date(from: text).map { makeOutputFormatter().string(from: $0) }
  }
}
