import AppCore
import ArgumentParser
import Foundation

struct StrategyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "strategy",
    abstract: "Manage learned fetch strategies.",
    subcommands: [List.self, Show.self, Learn.self, Update.self, Delete.self]
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List stored strategies.")

    @Flag(name: .long, help: "Output JSON instead of a table")
    var json = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      try await runReportingErrors {
        let gateway = try global.makeGateway()
        let stored = try await gateway.strategies()
        if json {
          try CLIOutput.printJSON(stored, pretty: true)
          return
        }
        if stored.isEmpty {
          print("No strategies stored.")
          return
        }
        for entry in stored {
          let strategy = entry.strategy
          print(
            "\(strategy.id)  v\(strategy.version)  \(strategy.extraction.kindName)  "
              + "ok:\(entry.successCount) fail:\(entry.failureCount)  \(strategy.sourceURL)  (\(strategy.name))"
          )
        }
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show one strategy by id or source URL.")

    @Argument(help: "Strategy id or source URL")
    var idOrURL: String

    @Flag(name: .long, help: "Compact JSON output")
    var json = false

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      try await runReportingErrors {
        let gateway = try global.makeGateway()
        guard let stored = try await gateway.strategy(idOrURL: idOrURL) else {
          throw GatewayError.noStrategy(sourceURL: idOrURL)
        }
        try CLIOutput.printJSON(stored, pretty: !json)
      }
    }
  }

  struct Learn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Learn (or re-learn) a fetch strategy for a URL via the LLM and store it."
    )

    @Argument(help: "Source URL")
    var url: String

    @Option(name: .long, help: "Number of latest items the strategy must produce")
    var count: Int = 20

    @Option(name: .long, help: "Free-text guidance for the learner")
    var hints: String?

    @Option(name: .long, help: "Path to a JSON Schema file the output items must conform to")
    var schemaFile: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      try await runReportingErrors {
        let gateway = try global.makeGateway()
        let strategy = try await gateway.learnStrategy(
          url: url,
          count: count,
          hints: hints,
          outputSchema: try readSchemaFile(schemaFile)
        )
        try CLIOutput.printJSON(strategy, pretty: true)
      }
    }
  }

  struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Re-learn an existing strategy (same id, version + 1)."
    )

    @Argument(help: "Strategy id or source URL")
    var idOrURL: String

    @Option(name: .long, help: "Number of latest items the strategy must produce")
    var count: Int = 20

    @Option(name: .long, help: "Free-text guidance for the learner")
    var hints: String?

    @Option(name: .long, help: "Path to a JSON Schema file the output items must conform to")
    var schemaFile: String?

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      try await runReportingErrors {
        let gateway = try global.makeGateway()
        let strategy = try await gateway.updateStrategy(
          idOrURL: idOrURL,
          count: count,
          hints: hints,
          outputSchema: try readSchemaFile(schemaFile)
        )
        try CLIOutput.printJSON(strategy, pretty: true)
      }
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a strategy by id or source URL.")

    @Argument(help: "Strategy id or source URL")
    var idOrURL: String

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      try await runReportingErrors {
        let gateway = try global.makeGateway()
        guard try await gateway.deleteStrategy(idOrURL: idOrURL) else {
          throw GatewayError.noStrategy(sourceURL: idOrURL)
        }
        print("Deleted.")
      }
    }
  }
}
