import Foundation

enum ProcessEvent: Sendable {
    case line(String)
    case exit(Int32)
}

enum ProcessRunner {
    /// A GUI app inherits launchd's bare PATH, which has neither uv (~/.local/bin) nor Homebrew.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }()

    /// Streams merged stdout and stderr line by line, then the exit status. Completion is driven by
    /// process termination rather than pipe EOF, because a grandchild that inherits the pipe would
    /// otherwise hold the stream open after the script has exited.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:],
        log: URL? = nil,
        includeStderr: Bool = true,
        timeout: Duration = .seconds(60)
    ) -> AsyncStream<ProcessEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment.merging(extraEnvironment) { $1 }

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = includeStderr ? pipe : FileHandle.nullDevice
            let splitter = LineSplitter(log: log) { continuation.yield(.line($0)) }
            let reader = pipe.fileHandleForReading

            reader.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { splitter.feed(data) }
            }
            process.terminationHandler = { finished in
                reader.readabilityHandler = nil
                splitter.feed(drainWithoutBlocking(reader))
                splitter.finish()
                continuation.yield(.exit(finished.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.line("error could not start \(executable.path): \(error.localizedDescription)"))
                continuation.yield(.exit(-1))
                continuation.finish()
                return
            }

            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, process.isRunning else { return }
                continuation.yield(.line("error timed out after \(timeout)"))
                process.terminate()
            }
            continuation.onTermination = { _ in
                watchdog.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Runs to completion and returns the exit status, ignoring output.
    static func status(_ executable: URL, _ arguments: [String], timeout: Duration = .seconds(30)) async -> Int32 {
        var status: Int32 = -1
        for await event in run(executable, arguments, timeout: timeout) {
            if case .exit(let code) = event { status = code }
        }
        return status
    }

    /// Runs to completion and returns stdout alone, for tools whose stdout is machine-readable but
    /// whose stderr carries log lines.
    static func output(_ executable: URL, _ arguments: [String], timeout: Duration = .seconds(30)) async -> (Int32, String) {
        var status: Int32 = -1
        var lines: [String] = []
        for await event in run(executable, arguments, includeStderr: false, timeout: timeout) {
            switch event {
            case .line(let line): lines.append(line)
            case .exit(let code): status = code
            }
        }
        return (status, lines.joined(separator: "\n"))
    }

    private static func drainWithoutBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Splits raw output into lines and mirrors it into the log. Fed from the pipe's reader queue and
/// from the termination handler, so it locks.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let logHandle: FileHandle?
    private let emit: @Sendable (String) -> Void

    init(log: URL?, emit: @escaping @Sendable (String) -> Void) {
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: log)
        } else {
            logHandle = nil
        }
        self.emit = emit
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            // The script appends xcodebuild output to the same file, so write at the current end.
            _ = try? logHandle?.seekToEnd()
            try? logHandle?.write(contentsOf: data)
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                emit(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
    }

    func finish() {
        lock.withLock {
            if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)) }
            buffer.removeAll()
            try? logHandle?.close()
        }
    }
}
