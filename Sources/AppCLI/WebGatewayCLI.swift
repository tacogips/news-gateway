import AppCore
import ArgumentParser
import Foundation

@main
struct WebGatewayCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "web-gateway",
    abstract: "News collection gateway with LLM-learned, SQLite-persisted fetch strategies.",
    version: Version.current,
    subcommands: [FetchCommand.self, StrategyCommand.self, ConfigCommand.self]
  )
}
