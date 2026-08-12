import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses RSS 2.0 and Atom feeds into item objects mapped onto the strategy's
/// output schema fields.
public enum RSSExtractor {
  /// Canonical feed entry fields available for mapping.
  public static let entryFields = ["title", "link", "published", "summary", "id", "author"]

  static let defaultFieldMap: [String: String] = [
    "title": "title",
    "url": "link",
    "link": "link",
    "publishedAt": "published",
    "published": "published",
    "summary": "summary",
    "description": "summary",
    "id": "id",
    "author": "author"
  ]

  public static func extract(from xml: String, spec: RSSExtraction, count: Int) throws -> [JSONValue] {
    let parser = FeedParser()
    let entries = try parser.parse(Data(xml.utf8))
    let fieldMap = spec.fieldMap.isEmpty ? defaultFieldMap : spec.fieldMap

    return entries.prefix(count).map { entry in
      var object: [String: JSONValue] = [:]
      for (outputField, feedField) in fieldMap {
        if let value = entry[feedField], !value.isEmpty {
          object[outputField] = .string(value)
        }
      }
      return .object(object)
    }
  }
}

private final class FeedParser: NSObject, XMLParserDelegate {
  private var entries: [[String: String]] = []
  private var current: [String: String]?
  private var elementStack: [String] = []
  private var textBuffer = ""
  private var parseError: Error?

  func parse(_ data: Data) throws -> [[String: String]] {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.shouldProcessNamespaces = true
    guard parser.parse() || !entries.isEmpty else {
      throw GatewayError.extraction(
        message: "Feed XML parse failed: \(parser.parserError?.localizedDescription ?? "unknown error")"
      )
    }
    return entries
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = elementName.lowercased()
    elementStack.append(name)
    textBuffer = ""

    if name == "item" || name == "entry" {
      current = [:]
    }

    // Atom links carry the URL in the href attribute.
    if name == "link", current != nil, let href = attributeDict["href"] {
      let rel = attributeDict["rel"] ?? "alternate"
      if rel == "alternate" || current?["link"] == nil {
        current?["link"] = href
      }
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    textBuffer += string
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    textBuffer += String(decoding: CDATABlock, as: UTF8.self)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = elementName.lowercased()
    defer {
      if !elementStack.isEmpty { elementStack.removeLast() }
      textBuffer = ""
    }

    if name == "item" || name == "entry" {
      if let entry = current {
        entries.append(entry)
      }
      current = nil
      return
    }

    guard current != nil else { return }
    let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    let insideAuthor = elementStack.dropLast().last == "author"

    switch name {
    case "title":
      setIfEmpty("title", text)
    case "link":
      setIfEmpty("link", text)
    case "pubdate", "published", "updated", "date":
      setIfEmpty("published", text)
    case "description", "summary", "content", "encoded":
      setIfEmpty("summary", text)
    case "guid", "id":
      setIfEmpty("id", text)
    case "author", "creator":
      setIfEmpty("author", text)
    case "name" where insideAuthor:
      setIfEmpty("author", text)
    default:
      break
    }
  }

  private func setIfEmpty(_ key: String, _ value: String) {
    if current?[key] == nil {
      current?[key] = value
    }
  }
}
