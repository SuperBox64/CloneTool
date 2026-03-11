import AppKit
import ServiceManagement

// Receives progress callbacks from agent over XPC
final class AgentProgressHandler: NSObject, AgentProgressProtocol, @unchecked Sendable {
    private let handler: @Sendable (UInt64, String) -> Void

    init(handler: @escaping @Sendable (UInt64, String) -> Void) {
        self.handler = handler
    }

    func progressUpdate(_ line: String) {
        let tokens = line.split(separator: " ")
        guard let firstToken = tokens.first, let bytes = UInt64(firstToken) else { return }

        var speedStr = ""
        if let speedIdx = tokens.lastIndex(where: { $0.hasSuffix("/s") }),
           speedIdx > tokens.startIndex {
            let speedNum = tokens[tokens.index(before: speedIdx)]
            speedStr = "\(speedNum) \(tokens[speedIdx])"
        }

        handler(bytes, speedStr)
    }
}

@MainActor @Observable
final class AgentService {
    var isRunning = false
    var statusLog: String = ""

    nonisolated static let agentID = "com.clonetool.agent"
    nonisolated let instanceID = UUID().uuidString

    nonisolated init() {}

    // MARK: - Register Agent

    var agentReady: Bool {
        SMAppService.agent(plistName: "com.clonetool.agent.plist").status == .enabled
    }

    func registerAgent() {
        let service = SMAppService.agent(plistName: "com.clonetool.agent.plist")

        if service.status == .notFound {
            appendLog("Agent not found in app bundle.")
            return
        }

        if service.status == .requiresApproval {
            appendLog("Agent needs approval in System Settings > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
            return
        }

        appendLog("Registering agent...")
        do {
            try service.register()
            appendLog("Agent is active.")
        } catch {
            if service.status == .enabled {
                appendLog("Updating agent...")
                try? service.unregister()
                do {
                    try service.register()
                    appendLog("Agent is active.")
                } catch {
                    appendLog("Agent update failed: \(error.localizedDescription)")
                }
            } else {
                appendLog("Agent registration failed: \(error.localizedDescription)")
            }
        }

        if service.status == .requiresApproval {
            appendLog("Please approve CloneTool in System Settings > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - XPC Connection

    nonisolated private func makeConnection(progressHandler: AgentProgressHandler) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: AgentService.agentID, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentToolProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: AgentProgressProtocol.self)
        connection.exportedObject = progressHandler
        connection.resume()
        return connection
    }

    // MARK: - Execute (user-level)

    nonisolated func executeScript(_ script: String, progressHandler: AgentProgressHandler) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let connection = makeConnection(progressHandler: progressHandler)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: (-1, "XPC error: \(error.localizedDescription)"))
            } as! AgentToolProtocol

            proxy.execute(script: script, instanceID: self.instanceID) { status, output in
                connection.invalidate()
                continuation.resume(returning: (status, output))
            }
        }
    }

    // MARK: - Private

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let timestamp = formatter.string(from: Date())
        statusLog += "[\(timestamp)] \(message)\n"
    }
}
