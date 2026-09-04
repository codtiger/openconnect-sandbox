import Darwin
import Foundation
import OpenConnectSandboxCore

@MainActor
final class SupervisorClient: ObservableObject, Identifiable {
    let id: UUID
    let profileID: UUID
    let socksPort: Int
    @Published private(set) var phase: ConnectionPhase = .stopped
    @Published private(set) var logs: [String] = []
    @Published private(set) var supervisorPID: Int32?

    var onExit: ((SupervisorClient, Int32, Bool) -> Void)?
    var onStateChange: ((SupervisorClient) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private var outputBuffer = Data()
    private var requestedStop = false

    init(profileID: UUID, socksPort: Int) {
        self.id = profileID
        self.profileID = profileID
        self.socksPort = socksPort
    }

    func start(supervisorPath: String, request: SupervisorStartRequest) throws {
        process.executableURL = URL(fileURLWithPath: supervisorPath)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consume(data) }
        }
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let value = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.appendLog(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        process.terminationHandler = { [weak self] task in
            Task { @MainActor in
                guard let self else { return }
                self.supervisorPID = nil
                if self.phase != .failed { self.phase = .stopped }
                self.onExit?(self, task.terminationStatus, self.requestedStop)
            }
        }

        try process.run()
        supervisorPID = process.processIdentifier
        let data = try JSONEncoder.ipc.encode(request)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    func stop() {
        guard process.isRunning, !requestedStop else { return }
        requestedStop = true
        phase = .stopping
        if let data = try? JSONEncoder.ipc.encode(SupervisorCommand(command: "stop")) {
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }
        try? input.fileHandleForWriting.close()

        DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak process] in
            guard let process, process.isRunning, process.processIdentifier > 1 else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func waitUntilExit() async {
        guard process.isRunning else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [process] in
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let event = try? JSONDecoder.configured.decode(SupervisorEvent.self, from: line) else {
                continue
            }
            if let eventPhase = event.phase { phase = eventPhase }
            if let message = event.message, !message.isEmpty { appendLog(message) }
            onStateChange?(self)
        }
    }

    private func appendLog(_ value: String) {
        guard !value.isEmpty else { return }
        logs.append(value)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }
}
