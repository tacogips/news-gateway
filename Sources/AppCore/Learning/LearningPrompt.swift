import Foundation

/// Builds the strategy-learning prompt sent through agent-gateway.
enum LearningPrompt {
  static let system = """
  You are a scraping-strategy engineer. Given a news source URL and a sample \
  of its raw content, you design a reusable, deterministic strategy document \
  that extracts the latest N items. You output strict JSON only, no prose, \
  no markdown fences.
  """

  static let strategySpec = """
  Respond with ONE JSON object with these fields:

  {
    "name": "short human-readable strategy name",
    "notes": "optional: what the source is, caveats",
    "backends": ["http"],            // ordered subset of: http, firecrawl, zenrows, kitesurf
    "acquisition": {
      "url": "URL to fetch (feed/API endpoint if one exists; may contain {count})",
      "format": "html" | "json" | "text",
      "renderJS": false,             // true only if content requires JS rendering
      "headers": { }                 // optional extra request headers
    },
    "extraction": <one of the four kinds below>,
    "outputSchema": <JSON Schema object describing ONE item>
  }

  Extraction kinds (field "kind" selects one):

  1. RSS/Atom feed (STRONGLY preferred when the site offers a feed; set
     acquisition.url to the feed URL):
     { "kind": "rss", "rss": { "fieldMap": { "<schemaField>": "<title|link|published|summary|id|author>" } } }

  2. CSS selectors over HTML:
     { "kind": "css", "css": {
         "itemSelector": "selector matching one element per article, newest first",
         "fields": {
           "<schemaField>": { "selector": "relative selector or null for the item element",
                               "attribute": "href/src/datetime or null for text",
                               "resolveURL": true }
         } } }

  3. JSON API (when acquisition.format is json):
     { "kind": "json", "json": {
         "itemsPath": "dot path to the items array, e.g. data.articles",
         "fields": { "<schemaField>": "path relative to one item, e.g. title or urls[0].url" }
       } }

  4. LLM extraction (LAST resort, only when no deterministic rule can work):
     { "kind": "llm", "llm": { "instructions": "what to extract" } }

  Rules:
  - Prefer rss > json > css > llm.
  - The strategy must work for future fetches of the same source, not just
    this sample.
  - outputSchema should use {"type":"object","required":[...],"properties":{...}}.
    Include at least a title and a url/link field unless told otherwise.
  """

  struct DiscoveredFeed: Sendable, Equatable {
    var url: String
    var sample: String
  }

  static func build(
    sourceURL: String,
    count: Int,
    sample: ScrapedContent,
    discoveredFeeds: [DiscoveredFeed] = [],
    hints: String?,
    requiredSchema: JSONValue?,
    existing: Strategy?,
    failures: [String],
    contentMaxChars: Int
  ) -> String {
    var sections: [String] = []
    sections.append("Design a fetch strategy for the latest \(count) items of this news source.")
    sections.append("Source URL: \(sourceURL)")

    if !discoveredFeeds.isEmpty {
      let feedBudget = max(contentMaxChars / (2 * discoveredFeeds.count), 2_000)
      var feedSection = "The page advertises these feeds. STRONGLY prefer a feed-based strategy "
        + "(kind rss, acquisition.url set to the feed URL) when a feed contains the items."
      for feed in discoveredFeeds {
        feedSection += "\n\nFeed: \(feed.url)\nFeed sample (truncated):\n\(feed.sample.prefix(feedBudget))"
      }
      sections.append(feedSection)
    }

    if let hints, !hints.isEmpty {
      sections.append("User hints:\n\(hints)")
    }
    if let requiredSchema, let text = try? requiredSchema.encodedString(pretty: true) {
      sections.append(
        "The output schema is FIXED by the caller. Use exactly this schema as outputSchema "
          + "and map fields onto it:\n\(text)"
      )
    }
    if let existing, let text = try? existing.encodedString() {
      sections.append("You are UPDATING this existing strategy (keep what works, fix what does not):\n\(text)")
    }
    if !failures.isEmpty {
      sections.append(
        "Previous attempts failed. Fix these problems:\n- "
          + failures.suffix(4).joined(separator: "\n- ")
      )
    }
    sections.append(strategySpec)
    sections.append("SAMPLE CONTENT (truncated) fetched from \(sample.url):\n\(sample.body.prefix(contentMaxChars))")
    return sections.joined(separator: "\n\n")
  }
}

extension Strategy {
  func encodedString() throws -> String {
    String(decoding: try JSONCoding.encoder.encode(self), as: UTF8.self)
  }
}
