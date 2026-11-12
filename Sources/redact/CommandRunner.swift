import Darwin
import Foundation
import RedactCore

enum CommandRunner {
    /// Runs `command` with `extraEnvironment` added. When `mask` is set, stdout and stderr are piped
    /// through a streaming redactor; otherwise the child inherits the terminal directly.
    /// Returns the child's exit status (128 + signal if it was killed).
    static func run(_ command: [String], extraEnvironment: [String: String], mask: Bool, notSecret: Set<String> = [],
                    stdout: FileHandle = .standardOutput, stderr: FileHandle = .standardError) -> Int32 {
        let secrets = extraEnvironment.filter { !notSecret.contains($0.key) }
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { environment[key] = value }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.environment = environment

        let group = DispatchGroup()
        if mask {
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            pump(outPipe, to: stdout, secrets: secrets, group: group)
            pump(errPipe, to: stderr, secrets: secrets, group: group)
        }

        // Forward Ctrl-C / termination to the child instead of dying first.
        for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_IGN) }
        let sources = [SIGINT, SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { if process.isRunning { kill(process.processIdentifier, sig) } }
            source.resume()
            return source
        }
        defer { sources.forEach { $0.cancel() } }

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("redact: could not start \(command.first ?? ""): \(error.localizedDescription)\n".utf8))
            return 127
        }
        process.waitUntilExit()
        group.wait()
        if process.terminationReason == .uncaughtSignal { return 128 + process.terminationStatus }
        return process.terminationStatus
    }

    private static func pump(_ pipe: Pipe, to handle: FileHandle, secrets: [String: String], group: DispatchGroup) {
        group.enter()
        let reader = pipe.fileHandleForReading
        DispatchQueue.global().async {
            let redactor = Redactor(secrets: secrets)
            let fd = reader.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                // Wait for output; if the command goes quiet with bytes held back, flush what is safe.
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, redactor.isHolding ? 100 : -1)
                if ready == 0 {
                    handle.write(Data(redactor.flushIdle()))
                    continue
                }
                if ready < 0 { if errno == EINTR { continue } else { break } }
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                handle.write(Data(redactor.feed(buffer[0..<n])))
            }
            handle.write(Data(redactor.finish()))
            group.leave()
        }
    }

    /// Runs a shell command and captures masked output (for MCP). Output is capped at `limit` bytes.
    static func capture(shell command: String, directory: String, extraEnvironment: [String: String],
                        timeout: TimeInterval, limit: Int = 60_000, notSecret: Set<String> = []) -> (status: Int32, output: String, timedOut: Bool) {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment { environment[key] = value }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var collected = Data()
        var truncated = false
        let redactor = Redactor(secrets: extraEnvironment.filter { !notSecret.contains($0.key) })
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let reader = pipe.fileHandleForReading
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                let masked = redactor.feed(data)
                lock.lock()
                if collected.count < limit { collected.append(contentsOf: masked.prefix(limit - collected.count)) } else { truncated = true }
                lock.unlock()
            }
            let tail = redactor.finish()
            lock.lock()
            if collected.count < limit { collected.append(contentsOf: tail.prefix(limit - collected.count)) }
            lock.unlock()
            done.signal()
        }
        do { try process.run() } catch { return (127, "could not start: \(error.localizedDescription)", false) }
        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if done.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
        }
        process.waitUntilExit()
        lock.lock()
        var text = String(decoding: collected, as: UTF8.self)
        lock.unlock()
        if truncated { text += "\n[output truncated at \(limit) bytes]" }
        return (process.terminationStatus, text, timedOut)
    }
}
