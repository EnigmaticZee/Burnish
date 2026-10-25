import Foundation

/// Runs a system tool (`ditto`, `hdiutil`, `tar`, `spctl`, `pkgutil`, `brew`) without a shell.
public enum Shell {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data

        public var succeeded: Bool { status == 0 }
        public var text: String { String(decoding: stdout, as: UTF8.self) }
        public var errorText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    public static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Drain both pipes while the tool runs so a chatty tool can't fill a pipe and stall.
        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { handle in collector.appendOut(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in collector.appendErr(handle.availableData) }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                let (o, e) = collector.result
                continuation.resume(returning: Output(status: finished.terminationStatus, stdout: o, stderr: e))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func appendOut(_ d: Data) { lock.withLock { out.append(d) } }
        func appendErr(_ d: Data) { lock.withLock { err.append(d) } }
        var result: (Data, Data) { lock.withLock { (out, err) } }
    }
}
