import Foundation
import Testing
@testable import AppCore

@Test func playwrightCommandBackendSubstitutesURLAndHeaders() async throws {
  let runner = BrowserProcessRunner()
  let backend = PlaywrightCommandBackend(
    runner: runner,
    commandTemplate: ["node", "fetch.mjs", "{url}", "{headers}"]
  )

  let content = try await backend.fetch(
    ScrapeRequest(url: "https://example.com/app", headers: ["X-Test": "value"])
  )

  #expect(content.body == "<html>Playwright</html>")
  let commands = await runner.commands
  #expect(commands.count == 1)
  #expect(commands[0].command == [
    "node", "fetch.mjs", "https://example.com/app", #"{"X-Test":"value"}"#
  ])
  #expect(commands[0].timeoutSeconds == 120)
}

@Test func agentBrowserBackendUsesIsolatedSessionAndClosesIt() async throws {
  let runner = BrowserProcessRunner()
  let backend = AgentBrowserBackend(runner: runner)

  let content = try await backend.fetch(
    ScrapeRequest(url: "https://example.com/app", headers: ["Authorization": "Bearer test"])
  )

  #expect(content.body == "<html>Agent Browser</html>")
  let commands = await runner.commands
  #expect(commands.count == 3)
  #expect(commands[0].command.first == "agent-browser")
  #expect(commands[0].command.contains("open"))
  #expect(commands[0].command.contains("https://example.com/app"))
  #expect(commands[0].command.contains(#"{"Authorization":"Bearer test"}"#))
  #expect(commands[1].command.contains("eval"))
  #expect(commands[1].command.contains("-b"))
  #expect(commands[2].command.last == "close")

  let session = try #require(value(after: "--session", in: commands[0].command))
  #expect(value(after: "--session", in: commands[1].command) == session)
  #expect(value(after: "--session", in: commands[2].command) == session)
}

private actor BrowserProcessRunner: ProcessRunner {
  struct Invocation: Sendable {
    let command: [String]
    let timeoutSeconds: Int?
  }

  private(set) var commands: [Invocation] = []

  func run(command: [String], stdin: String?, timeoutSeconds: Int?) async throws -> ProcessResult {
    commands.append(Invocation(command: command, timeoutSeconds: timeoutSeconds))
    if command.contains("eval") {
      return ProcessResult(
        exitCode: 0,
        stdout: #"{"success":true,"data":{"result":"<html>Agent Browser</html>"}}"#,
        stderr: ""
      )
    }
    if command.first == "agent-browser" {
      return ProcessResult(exitCode: 0, stdout: #"{"success":true,"data":{}}"#, stderr: "")
    }
    return ProcessResult(exitCode: 0, stdout: "<html>Playwright</html>", stderr: "")
  }
}

private func value(after marker: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: marker), arguments.indices.contains(index + 1) else {
    return nil
  }
  return arguments[index + 1]
}
