import Foundation

enum DiskService {

    static func listDisks() async throws -> [DiskInfo] {
        let output = try await shell("/usr/sbin/diskutil", arguments: ["list"])
        return parseDiskutilList(output)
    }

    static func diskSizeBytes(_ diskId: String) async throws -> UInt64 {
        let output = try await shell("/usr/sbin/diskutil", arguments: ["info", diskId])
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Disk Size:") || trimmed.hasPrefix("Total Size:") {
                if let openParen = trimmed.firstIndex(of: "(") {
                    let afterParen = trimmed[trimmed.index(after: openParen)...]
                    let digits = afterParen.prefix(while: { $0.isNumber })
                    if let value = UInt64(digits) { return value }
                }
            }
        }
        return 0
    }

    static func unmountDisk(_ diskId: String) async throws -> String {
        try await shell("/usr/sbin/diskutil", arguments: ["unmountDisk", "/dev/\(diskId)"])
    }

    // MARK: - Parsing

    static func parseDiskutilList(_ output: String) -> [DiskInfo] {
        var disks: [DiskInfo] = []
        let lines = output.components(separatedBy: "\n")

        var currentId = ""
        var currentMediaType = ""
        var currentSize = ""
        var currentNames: [String] = []

        for line in lines {
            if line.hasPrefix("/dev/") {
                if !currentId.isEmpty {
                    disks.append(DiskInfo(
                        id: currentId,
                        mediaType: currentMediaType,
                        size: currentSize,
                        sizeBytes: 0,
                        partitionNames: currentNames
                    ))
                }
                let parts = line.split(separator: " ", maxSplits: 1)
                currentId = String(parts[0]).replacingOccurrences(of: "/dev/", with: "")
                currentMediaType = ""
                if let open = line.firstIndex(of: "("),
                   let close = line.firstIndex(of: ")") {
                    currentMediaType = String(line[line.index(after: open)..<close])
                }
                currentSize = ""
                currentNames = []
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":"),
                  let idx = Int(trimmed[trimmed.startIndex..<colonIdx]) else {
                continue
            }

            let tokens = trimmed[trimmed.index(after: colonIdx)...]
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ")
                .map(String.init)

            guard tokens.count >= 3 else { continue }

            let sizeUnit = tokens[tokens.count - 2]
            let sizeNum = tokens[tokens.count - 3].replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "+", with: "")
            let identifier = tokens[tokens.count - 1]

            if idx == 0 {
                currentSize = "\(sizeNum) \(sizeUnit)"
            }

            // Extract name: everything between type and size fields
            if tokens.count > 4 {
                let name = tokens[1..<(tokens.count - 3)].joined(separator: " ")
                if !name.isEmpty && name != "-" {
                    currentNames.append(name)
                }
            }

            _ = identifier
        }

        if !currentId.isEmpty {
            disks.append(DiskInfo(
                id: currentId,
                mediaType: currentMediaType,
                size: currentSize,
                sizeBytes: 0,
                partitionNames: currentNames
            ))
        }

        return disks
    }

    // MARK: - Shell

    @discardableResult
    private static func shell(_ path: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
