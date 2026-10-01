import Foundation

public enum GitError: Error, LocalizedError {
    case unavailable
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Git is unavailable. Install the Xcode command line tools."
        case .timedOut:
            return "Git took too long to respond."
        case .failed(let message):
            return message.isEmpty ? "Git command failed." : message
        }
    }
}

enum GitRunner {
    static func run(_ arguments: [String], at directory: URL, timeout: TimeInterval = 20,
                    successfulExitCodes: Set<Int32> = [0], maximumOutputBytes: Int? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "Never"
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=8"
        }
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw GitError.unavailable
        }

        let state = TimeoutState()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard process.isRunning else { return }
            state.markTimedOut()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timer.resume()

        // Drain both pipes concurrently so a verbose Git error cannot block a large status result.
        let errorCapture = LockedData()
        let errorDrain = DispatchGroup()
        errorDrain.enter()
        // A dedicated reader must not wait behind Swift's cooperative inspection tasks.
        // Those tasks can all be blocked on subprocess completion at the same time.
        Thread.detachNewThread {
            errorCapture.set(drain(errorPipe.fileHandleForReading, limit: maximumOutputBytes))
            errorDrain.leave()
        }
        let output = drain(outputPipe.fileHandleForReading, limit: maximumOutputBytes)
        process.waitUntilExit()
        errorDrain.wait()
        timer.cancel()

        if state.didTimeOut { throw GitError.timedOut }
        if let limit = maximumOutputBytes, output.count > limit || errorCapture.data.count > limit {
            throw GitError.failed("Git output exceeded the inspection limit.")
        }
        guard successfulExitCodes.contains(process.terminationStatus) else {
            let message = String(decoding: errorCapture.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.failed(message)
        }
        return output
    }

    private static func drain(_ handle: FileHandle, limit: Int?) -> Data {
        var data = Data()
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let limit { data.append(chunk.prefix(max(0, limit + 1 - data.count))) }
            else { data.append(chunk) }
        }
        return data
    }

    static func text(_ arguments: [String], at directory: URL, timeout: TimeInterval = 20) throws -> String {
        String(decoding: try run(arguments, at: directory, timeout: timeout), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LockedData {
    private let lock = NSLock()
    private var value = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }
}

private final class TimeoutState {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}
