import AppCore
import ArgumentParser
import Foundation

struct FetchCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fetch",
    abstract: "Fetch the latest N items from a source URL using its stored strategy."
  )

  @Argument(help: "Source URL")
  var url: String

  @Option(name: .long, help: "Number of latest items to fetch")
  var count: Int = 20

  @Flag(name: .long, help: "Learn a strategy first when none is stored for the URL")
  var learnIfMissing = false

  @Flag(name: .long, help: "Re-learn the strategy and retry once when all fetch attempts fail")
  var relearnOnFailure = false

  @Option(name: .long, help: "Override the strategy's retry attempt count")
  var maxAttempts: Int?

  @Flag(name: .long, help: "Pretty-print the output JSON")
  var pretty = false

  @OptionGroup var global: GlobalOptions

  func run() async throws {
    try await runReportingErrors {
      let gateway = try global.makeGateway()
      let output = try await gateway.fetchLatest(
        url: url,
        count: count,
        learnIfMissing: learnIfMissing,
        relearnOnFailure: relearnOnFailure,
        maxAttempts: maxAttempts
      )
      try CLIOutput.printJSON(output, pretty: pretty)
    }
  }
}
