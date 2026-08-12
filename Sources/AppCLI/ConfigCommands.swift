import AppCore
import ArgumentParser
import Foundation

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Manage gateway configuration.",
    subcommands: [Init.self, Show.self]
  )

  struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write a default config template.")

    @Option(name: .long, help: "Destination path (default: ~/.config/news-gateway/config.json)")
    var path: String?

    @Flag(name: .long, help: "Overwrite an existing file")
    var force = false

    func run() async throws {
      try await runReportingErrors {
        let destination = GatewayConfig.expand(path ?? GatewayConfig.defaultConfigPath)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination), !force {
          throw GatewayError.invalidInput(message: "\(destination) already exists; pass --force to overwrite")
        }
        let directory = (destination as NSString).deletingLastPathComponent
        if !directory.isEmpty {
          try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try Data(GatewayConfig.templateJSON.utf8).write(to: URL(fileURLWithPath: destination))
        print("Wrote \(destination)")
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the resolved configuration.")

    @OptionGroup var global: GlobalOptions

    func run() async throws {
      try await runReportingErrors {
        let config = try global.loadConfig()
        try CLIOutput.printJSON(config, pretty: true)
        let environment = ProcessInfo.processInfo.environment
        FileHandle.standardError.write(
          Data("db: \(config.resolvedDBPath(override: global.db, environment: environment))\n".utf8)
        )
      }
    }
  }
}
