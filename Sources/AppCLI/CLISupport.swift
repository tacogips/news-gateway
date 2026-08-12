import AppCore
import ArgumentParser
import Foundation

struct GlobalOptions: ParsableArguments {
  @Option(name: .long, help: "Config file path (default: ~/.config/news-gateway/config.json)")
  var config: String?

  @Option(name: .long, help: "SQLite database path (default from config or ~/.local/share/news-gateway/)")
  var db: String?

  func loadConfig() throws -> GatewayConfig {
    try GatewayConfig.load(path: config, environment: ProcessInfo.processInfo.environment)
  }

  func makeGateway() throws -> NewsGateway {
    try NewsGateway(config: try loadConfig(), dbPathOverride: db)
  }
}

/// Stable exit codes; see design-docs/specs/command.md.
enum CLIExit {
  static func code(for error: Error) -> Int32 {
    guard let gatewayError = error as? GatewayError else { return 1 }
    switch gatewayError {
    case .invalidInput: return 2
    case .fetchFailed: return 3
    case .noStrategy: return 4
    case .learningFailed: return 5
    case .configuration: return 6
    case .backend, .extraction: return 1
    }
  }
}

enum CLIOutput {
  static func printJSON<T: Encodable>(_ value: T, pretty: Bool) throws {
    let encoder = pretty ? JSONCoding.prettyEncoder : JSONCoding.encoder
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
  }

  static func printErrorJSON(_ error: Error) {
    let gatewayError = error as? GatewayError
    let payload: JSONValue = .object([
      "error": .object([
        "code": .string(gatewayError?.code ?? "internal"),
        "message": .string(gatewayError.map(\.description) ?? String(describing: error))
      ])
    ])
    let text = (try? payload.encodedString()) ?? "{\"error\":{\"code\":\"internal\"}}"
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
}

/// Runs a gateway operation, mapping failures to the stable error contract.
func runReportingErrors<T: Sendable>(_ body: () async throws -> T) async throws -> T {
  do {
    return try await body()
  } catch let error as ExitCode {
    throw error
  } catch {
    CLIOutput.printErrorJSON(error)
    throw ExitCode(CLIExit.code(for: error))
  }
}

func readSchemaFile(_ path: String?) throws -> JSONValue? {
  guard let path else { return nil }
  let expanded = GatewayConfig.expand(path)
  guard let data = FileManager.default.contents(atPath: expanded) else {
    throw GatewayError.invalidInput(message: "Schema file not found: \(expanded)")
  }
  do {
    return try JSONValue(parsing: data)
  } catch {
    throw GatewayError.invalidInput(message: "Schema file is not valid JSON: \(error)")
  }
}
