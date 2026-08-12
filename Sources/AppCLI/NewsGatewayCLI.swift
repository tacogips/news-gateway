import AppCore
import ArgumentParser
import Foundation

@main
struct NewsGatewayCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "news-gateway",
    abstract: "News collection gateway with LLM-learned, SQLite-persisted fetch strategies.",
    version: Version.current,
    subcommands: [FetchCommand.self, StrategyCommand.self, ConfigCommand.self]
  )
}
