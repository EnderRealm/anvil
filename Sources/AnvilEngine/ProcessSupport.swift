import Foundation

// Shared subprocess plumbing used by both the streaming engine and the batch tk client.
// Reads are event-driven and the exit wait runs on a dedicated thread, so no pooled
// concurrency worker is ever held blocked.
enum ProcessSupport {
    struct Output: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    // Run a short, one-shot command to completion, collecting stdout/stderr.
    static func run(executableURL: URL, arguments: [String], cwd: URL? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // Drain both pipes concurrently to avoid a full-buffer deadlock.
        async let out = readToEnd(outPipe.fileHandleForReading)
        async let err = readToEnd(errPipe.fileHandleForReading)
        let outData = await out
        let errData = await err
        let exitCode = await waitForExit(process)

        return Output(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            exitCode: exitCode
        )
    }

    static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let box = DataBox()
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    fh.readabilityHandler = nil
                    let data = box.snapshot()
                    try? fh.close()
                    continuation.resume(returning: data)
                    return
                }
                box.append(chunk)
            }
        }
    }

    // `Process.waitUntilExit()` blocks; run it on a dedicated thread so it never competes for
    // a pooled worker.
    static func waitForExit(_ process: Process) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let thread = Thread {
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
            thread.start()
        }
    }

    // Resolve an executable from PATH plus the well-known install locations a GUI/launchd
    // context may be missing from its inherited PATH. Returns a bare-name URL if nothing is
    // found; callers validate executability and surface a clear error.
    static func resolveExecutable(named name: String, extraDirectories: [String] = []) -> URL {
        let fm = FileManager.default
        var dirs: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        let home = fm.homeDirectoryForCurrentUser
        dirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".local/bin").path,
        ])
        dirs.append(contentsOf: extraDirectories)
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: name)
    }
}

// Accumulates pipe bytes; touched only from a FileHandle's serial readability queue.
private final class DataBox: @unchecked Sendable {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    func snapshot() -> Data { data }
}
