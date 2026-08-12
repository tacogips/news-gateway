import Foundation
import SwiftSoup

/// Finds RSS/Atom feeds advertised by an HTML page
/// (`<link rel="alternate" type="application/rss+xml|atom+xml">`).
/// Feeds are the most reliable strategy target, so discovered feeds are
/// sampled and shown to the learner alongside the page itself.
enum FeedAutodiscovery {
  static let feedTypes: Set<String> = [
    "application/rss+xml",
    "application/atom+xml",
    "application/feed+json"
  ]

  /// Absolute feed URLs in document order, deduplicated.
  static func feedURLs(inHTML html: String, pageURL: String) -> [String] {
    guard let document = try? SwiftSoup.parse(html, pageURL) else { return [] }
    guard let links = try? document.select("link[rel=alternate]") else { return [] }

    var seen = Set<String>()
    var urls: [String] = []
    for link in links.array() {
      guard
        let type = try? link.attr("type").lowercased(),
        feedTypes.contains(type),
        let href = try? link.attr("href"),
        !href.isEmpty
      else { continue }
      let absolute: String
      if let base = URL(string: pageURL), let resolved = URL(string: href, relativeTo: base) {
        absolute = resolved.absoluteString
      } else {
        absolute = href
      }
      if seen.insert(absolute).inserted {
        urls.append(absolute)
      }
    }
    return urls
  }

  /// True when the body looks like an HTML page rather than a feed/API
  /// payload (feeds need no autodiscovery pass).
  static func looksLikeHTMLPage(_ body: String) -> Bool {
    let head = body.prefix(2_000).lowercased()
    return head.contains("<html") || head.contains("<!doctype html")
  }
}
