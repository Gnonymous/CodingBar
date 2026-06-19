import Foundation

/// Thread-safe byte accumulator: the stdout readability handler appends from a
/// dispatch queue while the caller reads the result, so access must be locked.
private final class DataHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Spawns a child process with a hard timeout. Returns its exit status and stdout,
/// or nil on spawn failure or timeout.
///
/// This deliberately never pins a libdispatch worker thread on the child. The old
/// path did — `DispatchQueue.global { proc.waitUntilExit() }` stayed blocked even
/// after the child had exited (a notification race across sleep/wake), so one
/// thread leaked per timed-out child and they accumulated across the 30s refresh
/// timer until the GCD 64-thread soft limit wedged the whole pool, including the
/// Swift-concurrency path that drives the panel — the overnight "popover opens but
/// is frozen" bug. Here completion is signalled by `terminationHandler` (a dispatch
/// proc source) and stdout is read by an event-driven `readabilityHandler` (invoked
/// on a queue only when bytes are ready, never blocked). Continuous draining of BOTH
/// stdout and stderr stops a child whose output exceeds the 64KB pipe buffer from
/// wedging on write. On timeout we escalate to SIGKILL (SIGTERM is ignorable) and
/// just detach the readers — even a grandchild still holding the pipe leaks nothing,
/// because no thread was ever waiting on it.
enum Subprocess {

    struct Result: Sendable {
        let status: Int32
        let stdout: Data
    }

    static func run(_ executable: URL, _ args: [String], timeout: TimeInterval) -> Result? {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let holder = DataHolder()
        let readEOF = DispatchSemaphore(value: 0)
        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; readEOF.signal() }  // EOF
            else { holder.append(chunk) }
        }
        // Drain stderr too (discarding it): a child that writes more than the 64KB
        // pipe buffer to stderr would otherwise block on write until we time out.
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { h in
            if h.availableData.isEmpty { h.readabilityHandler = nil }
        }

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            try proc.run()
        } catch {
            outHandle.readabilityHandler = nil
            errHandle.readabilityHandler = nil
            return nil
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(proc.processIdentifier, SIGKILL)   // hard-kill a wedged child
            _ = exited.wait(timeout: .now() + 2)    // let the proc source reap it (keeps proc alive past the kill)
            outHandle.readabilityHandler = nil      // detach; no thread is blocked on the pipe
            errHandle.readabilityHandler = nil
            return nil
        }
        _ = readEOF.wait(timeout: .now() + 2)       // collect any bytes buffered between last chunk and exit
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        return Result(status: proc.terminationStatus, stdout: holder.snapshot())
    }
}
