import Foundation

@MainActor
@Observable
final class AuthService {

    // MARK: - Types

    enum AuthState: Equatable, Sendable {
        case idle
        case authenticating
        case waitingForUser(url: String?)
        case success
        case error(String)
    }

    enum ProcessEvent: Sendable {
        case output(String)
        case pid(Int32)
        case exit(Int32)
    }

    /// Wrapper to allow retaining Process across @Sendable boundaries.
    private final class ProcessRef: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    // MARK: - State

    var state: AuthState = .idle
    var outputLines: [String] = []

    private var currentTask: Task<Void, Never>?
    private var runningPID: Int32?

    var isAuthenticated: Bool {
        if case .success = state { return true }
        return false
    }

    // MARK: - Public API

    func authenticateClaude(openclawPath: String) {
        runAuth(path: openclawPath, arguments: ["models", "auth", "setup-token", "--provider", "anthropic"])
    }

    func authenticateOpenAI(openclawPath: String) {
        runAuth(path: openclawPath, arguments: ["models", "auth", "login", "--provider", "openai"])
    }

    func pasteToken(openclawPath: String, provider: String, apiKey: String) {
        runAuth(
            path: openclawPath,
            arguments: ["models", "auth", "paste-token", "--provider", provider],
            input: apiKey
        )
    }

    func cancel() {
        if let pid = runningPID {
            kill(pid, SIGTERM)
            runningPID = nil
        }
        currentTask?.cancel()
        state = .idle
        outputLines = []
    }

    func reset() {
        cancel()
    }

    // MARK: - Private

    private func runAuth(path: String, arguments: [String], input: String? = nil) {
        cancel()
        state = .authenticating
        outputLines = []

        currentTask = Task { [weak self] in
            let events = Self.processEvents(path: path, arguments: arguments, input: input)

            for await event in events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .output(let text):
                    handleOutput(text)
                case .pid(let pid):
                    runningPID = pid
                case .exit(let code):
                    runningPID = nil
                    if code == 0 {
                        state = .success
                    } else if case .idle = state {
                        // Was cancelled — don't override
                    } else {
                        state = .error("认证失败 (代码: \(code))")
                    }
                }
            }
        }
    }

    private func handleOutput(_ text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        outputLines.append(contentsOf: lines)

        for line in lines {
            if let url = Self.extractURL(from: line) {
                state = .waitingForUser(url: url)
            }
        }
    }

    // MARK: - URL Detection

    private static func extractURL(from text: String) -> String? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }

        let range = NSRange(text.startIndex..., in: text)
        if let match = detector.firstMatch(in: text, range: range),
           let urlRange = Range(match.range, in: text) {
            let urlString = String(text[urlRange])
            // Only return http(s) URLs
            if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                return urlString
            }
        }
        return nil
    }

    // MARK: - Process Execution

    /// Runs an openclaw CLI command and streams events back via AsyncStream.
    /// This is `nonisolated` + `static` so the Process work doesn't block MainActor.
    nonisolated private static func processEvents(
        path: String,
        arguments: [String],
        input: String?
    ) -> AsyncStream<ProcessEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            if let inputText = input, let data = inputText.data(using: .utf8) {
                let inPipe = Pipe()
                process.standardInput = inPipe
                inPipe.fileHandleForWriting.write(data)
                inPipe.fileHandleForWriting.closeFile()
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                continuation.yield(.output(text))
            }

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                continuation.yield(.output(text))
            }

            process.terminationHandler = { proc in
                continuation.yield(.exit(proc.terminationStatus))
                continuation.finish()
            }

            do {
                try process.run()
                let pid = process.processIdentifier
                continuation.yield(.pid(pid))

                // Retain process so it isn't deallocated before exit.
                let ref = ProcessRef(process)
                continuation.onTermination = { @Sendable _ in
                    if ref.process.isRunning {
                        ref.process.terminate()
                    }
                }
            } catch {
                continuation.yield(.exit(-1))
                continuation.finish()
            }
        }
    }
}
