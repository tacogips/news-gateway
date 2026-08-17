import Foundation

public struct ProcessResult: Sendable, Equatable {
  public var exitCode: Int32
  public var stdout: String
  public var stderr: String

  public init(exitCode: Int32, stdout: String, stderr: String) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Injection point for subprocess execution by command-mode LLM clients and
/// local browser backends; tests use a fake. A nil timeout means no limit.
public protocol ProcessRunner: Sendable {
  func run(command: [String], stdin: String?, timeoutSeconds: Int?) async throws -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunner {
  public init() {}

  public func run(command: [String], stdin: String?, timeoutSeconds: Int?) async throws -> ProcessResult {
    guard !command.isEmpty else {
      throw GatewayError.invalidInput(message: "Empty command")
    }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
          process.arguments = command

          let stdoutPipe = Pipe()
          let stderrPipe = Pipe()
          let stdinPipe = Pipe()
          process.standardOutput = stdoutPipe
          process.standardError = stderrPipe
          process.standardInput = stdinPipe

          try process.run()

          let timedOut = TimeoutFlag()
          var watchdog: DispatchWorkItem?
          if let timeoutSeconds, timeoutSeconds > 0 {
            let item = DispatchWorkItem {
              timedOut.set()
              process.terminate()
            }
            watchdog = item
            DispatchQueue.global(qos: .utility)
              .asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: item)
          }

          if let stdin {
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
          }
          stdinPipe.fileHandleForWriting.closeFile()

          let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
          let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
          process.waitUntilExit()
          watchdog?.cancel()

          if timedOut.isSet {
            continuation.resume(
              throwing: GatewayError.backend(
                name: "process",
                message: "Command timed out after \(timeoutSeconds ?? 0)s: \(command.joined(separator: " "))"
              )
            )
            return
          }

          continuation.resume(
            returning: ProcessResult(
              exitCode: process.terminationStatus,
              stdout: String(decoding: stdoutData, as: UTF8.self),
              stderr: String(decoding: stderrData, as: UTF8.self)
            )
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

/// Lock-protected flag shared between the watchdog and the waiting thread.
private final class TimeoutFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
