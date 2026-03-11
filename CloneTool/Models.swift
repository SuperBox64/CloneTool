import Foundation

struct DiskInfo: Identifiable, Hashable {
    let id: String
    let mediaType: String
    let size: String
    let sizeBytes: UInt64
    let partitionNames: [String]

    var devicePath: String { "/dev/\(id)" }
    var rawDevicePath: String { "/dev/r\(id)" }
    var isExternal: Bool { mediaType.contains("external") }
    var isInternal: Bool { mediaType.contains("internal") }
    var isDiskImage: Bool { mediaType.contains("disk image") }
    var isSynthesized: Bool { mediaType.contains("synthesized") }

    var displayName: String {
        let names = partitionNames.filter { !$0.isEmpty }
        let label = names.isEmpty ? id : names.joined(separator: ", ")
        return "\(label) (\(size)) [\(id)]"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DiskInfo, rhs: DiskInfo) -> Bool { lhs.id == rhs.id }
}

enum OperationSchema: String, CaseIterable, Identifiable {
    case diskToImage = "Disk to Image"
    case imageToDisk = "Image to Disk"
    case diskToDisk = "Disk to Disk"

    var id: String { rawValue }
}

enum OperationState: Equatable {
    case idle
    case running
    case completed
    case error(String)
}
