#!/usr/bin/env swift
// CloneOperationsTest.swift
// Integration tests for Disk to Image, Image to Disk, and Disk to Disk
// Uses hdiutil to create DMG-backed virtual disks as test fixtures.
//
// Usage: sudo swift Tests/CloneOperationsTest.swift
// (sudo required for raw disk access via /dev/rdiskN)

import Foundation

// MARK: - Test Helpers

let fm = FileManager.default
let testDir = fm.temporaryDirectory.appendingPathComponent("CloneToolTests_\(ProcessInfo.processInfo.processIdentifier)")
let pigzPath = "\(fm.currentDirectoryPath)/CloneTool/Binaries/pigz"
let dmgSize = "32m" // small enough to be fast

struct TestDisk {
    let dmgPath: String
    let devicePath: String    // e.g. /dev/disk9
    let rawDevicePath: String // e.g. /dev/rdisk9
}

var createdDisks: [TestDisk] = []
var passed = 0
var failed = 0

func shell(_ command: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus, output)
}

func createTestDisk(name: String, fill: Bool = false) -> TestDisk? {
    let dmgPath = testDir.appendingPathComponent("\(name).dmg").path

    // Create a blank DMG
    let create = shell("hdiutil create -size \(dmgSize) -fs HFS+ -volname \(name) '\(dmgPath)' -ov")
    guard create.status == 0 else {
        print("  FAIL: Could not create DMG: \(create.output)")
        return nil
    }

    // Attach without mounting filesystem (we want raw block access)
    let attach = shell("hdiutil attach '\(dmgPath)' -nomount -noverify")
    guard attach.status == 0 else {
        print("  FAIL: Could not attach DMG: \(attach.output)")
        return nil
    }

    // Parse device path from output (e.g. "/dev/disk9")
    let lines = attach.output.components(separatedBy: "\n")
    guard let deviceLine = lines.first(where: { $0.contains("/dev/disk") }),
          let device = deviceLine.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first else {
        print("  FAIL: Could not parse device path from: \(attach.output)")
        return nil
    }

    let rawDevice = device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")

    // Optionally fill with recognizable pattern
    if fill {
        let fillResult = shell("dd if=/dev/urandom of=\(rawDevice) bs=1m count=16 2>/dev/null")
        if fillResult.status != 0 {
            print("  WARNING: Could not fill disk with pattern")
        }
    }

    let disk = TestDisk(dmgPath: dmgPath, devicePath: device, rawDevicePath: rawDevice)
    createdDisks.append(disk)
    return disk
}

func detachDisk(_ disk: TestDisk) {
    _ = shell("hdiutil detach \(disk.devicePath) -force 2>/dev/null")
}

func assert(_ condition: Bool, _ message: String) {
    if condition {
        print("  PASS: \(message)")
        passed += 1
    } else {
        print("  FAIL: \(message)")
        failed += 1
    }
}

func diskChecksum(_ rawDevice: String, bytes: Int) -> String {
    let result = shell("dd if=\(rawDevice) bs=1m count=\(bytes / (1024*1024)) 2>/dev/null | shasum -a 256")
    return result.output.components(separatedBy: " ").first ?? ""
}

// MARK: - Setup

print("=== CloneTool Integration Tests ===\n")

// Check sudo
let whoami = shell("whoami")
if whoami.output.trimmingCharacters(in: .whitespacesAndNewlines) != "root" {
    print("ERROR: These tests require sudo for raw disk access.")
    print("Usage: sudo swift Tests/CloneOperationsTest.swift")
    exit(1)
}

// Check pigz
guard fm.fileExists(atPath: pigzPath) else {
    print("ERROR: pigz not found at \(pigzPath)")
    exit(1)
}

try? fm.createDirectory(at: testDir, withIntermediateDirectories: true)
print("Test directory: \(testDir.path)\n")

// MARK: - Test 1: Disk to Image (uncompressed)

print("--- Test 1: Disk to Image (uncompressed) ---")
if let source = createTestDisk(name: "source1", fill: true) {
    let imagePath = testDir.appendingPathComponent("test1.img").path
    let sourceHash = diskChecksum(source.rawDevicePath, bytes: 16 * 1024 * 1024)

    let result = shell("dd if=\(source.rawDevicePath) of='\(imagePath)' bs=16m status=none")
    assert(result.status == 0, "dd completed successfully")
    assert(fm.fileExists(atPath: imagePath), "Image file created")

    // Verify by reading image checksum
    let imageHash = shell("dd if='\(imagePath)' bs=1m count=16 2>/dev/null | shasum -a 256")
        .output.components(separatedBy: " ").first ?? ""
    assert(sourceHash == imageHash, "Image matches source disk (SHA-256)")

    detachDisk(source)
    print()
}

// MARK: - Test 2: Disk to Image (compressed with pigz)

print("--- Test 2: Disk to Image (compressed with pigz) ---")
if let source = createTestDisk(name: "source2", fill: true) {
    let imagePath = testDir.appendingPathComponent("test2.img.gz").path
    let sourceHash = diskChecksum(source.rawDevicePath, bytes: 16 * 1024 * 1024)

    let result = shell("dd if=\(source.rawDevicePath) bs=16m status=none | '\(pigzPath)' > '\(imagePath)'")
    assert(result.status == 0, "dd | pigz completed successfully")
    assert(fm.fileExists(atPath: imagePath), "Compressed image file created")

    // Verify by decompressing to file and checking hash
    let decompPath = testDir.appendingPathComponent("test2_decomp.img").path
    _ = shell("'\(pigzPath)' -d -c '\(imagePath)' > '\(decompPath)' 2>/dev/null")
    let decompHash = shell("shasum -a 256 '\(decompPath)'").output.components(separatedBy: " ").first ?? ""
    let sourceFullHash = shell("dd if=\(source.rawDevicePath) bs=16m status=none 2>/dev/null | shasum -a 256")
        .output.components(separatedBy: " ").first ?? ""
    assert(sourceFullHash == decompHash, "Decompressed image matches source (SHA-256)")

    // Verify compression actually reduced size
    let origSize = 32 * 1024 * 1024
    let compressedSize = (try? fm.attributesOfItem(atPath: imagePath)[.size] as? Int) ?? origSize
    assert(compressedSize < origSize, "Compressed file is smaller than raw (\(compressedSize) < \(origSize))")

    detachDisk(source)
    print()
}

// MARK: - Test 3: Image to Disk (uncompressed)

print("--- Test 3: Image to Disk (uncompressed) ---")
if let source = createTestDisk(name: "source3", fill: true) {
    let imagePath = testDir.appendingPathComponent("test3.img").path
    let sourceHash = diskChecksum(source.rawDevicePath, bytes: 16 * 1024 * 1024)

    // Create image from source
    _ = shell("dd if=\(source.rawDevicePath) of='\(imagePath)' bs=16m status=none")
    detachDisk(source)

    // Create a blank target disk and write image to it
    if let target = createTestDisk(name: "target3") {
        let result = shell("dd if='\(imagePath)' of=\(target.rawDevicePath) bs=16m status=none")
        assert(result.status == 0, "dd to target completed successfully")

        let targetHash = diskChecksum(target.rawDevicePath, bytes: 16 * 1024 * 1024)
        assert(sourceHash == targetHash, "Target disk matches original source (SHA-256)")

        detachDisk(target)
    }
    print()
}

// MARK: - Test 4: Image to Disk (compressed with pigz)

print("--- Test 4: Image to Disk (compressed with pigz) ---")
if let source = createTestDisk(name: "source4", fill: true) {
    let imagePath = testDir.appendingPathComponent("test4.img.gz").path
    let sourceHash = diskChecksum(source.rawDevicePath, bytes: 16 * 1024 * 1024)

    // Create compressed image from source
    _ = shell("dd if=\(source.rawDevicePath) bs=16m status=none | '\(pigzPath)' > '\(imagePath)'")
    detachDisk(source)

    // Create a blank target disk and decompress image to it
    if let target = createTestDisk(name: "target4") {
        let result = shell("'\(pigzPath)' -d -c '\(imagePath)' | dd of=\(target.rawDevicePath) bs=16m status=none")
        assert(result.status == 0, "pigz -d | dd to target completed successfully")

        let targetHash = diskChecksum(target.rawDevicePath, bytes: 16 * 1024 * 1024)
        assert(sourceHash == targetHash, "Target disk matches original source (SHA-256)")

        detachDisk(target)
    }
    print()
}

// MARK: - Test 5: Disk to Disk

print("--- Test 5: Disk to Disk ---")
if let source = createTestDisk(name: "source5", fill: true) {
    let sourceHash = diskChecksum(source.rawDevicePath, bytes: 16 * 1024 * 1024)

    if let target = createTestDisk(name: "target5") {
        let result = shell("dd if=\(source.rawDevicePath) of=\(target.rawDevicePath) bs=16m status=none")
        assert(result.status == 0, "dd disk-to-disk completed successfully")

        let targetHash = diskChecksum(target.rawDevicePath, bytes: 16 * 1024 * 1024)
        assert(sourceHash == targetHash, "Target disk is byte-identical to source (SHA-256)")

        detachDisk(target)
    }
    detachDisk(source)
    print()
}

// MARK: - Test 6: pigz output is gzip-compatible

print("--- Test 6: pigz output is gzip-compatible ---")
if let source = createTestDisk(name: "source6", fill: true) {
    let imagePath = testDir.appendingPathComponent("test6.img.gz").path

    // Compress with pigz
    _ = shell("dd if=\(source.rawDevicePath) bs=16m status=none | '\(pigzPath)' > '\(imagePath)'")

    // Decompress with system gunzip (not pigz) to verify compatibility
    let rawPath = testDir.appendingPathComponent("test6_gunzip.img").path
    let gunzipResult = shell("gunzip -c '\(imagePath)' > '\(rawPath)' 2>/dev/null")
    assert(gunzipResult.status == 0, "gunzip can decompress pigz output")

    let gunzipHash = shell("shasum -a 256 '\(rawPath)'").output.components(separatedBy: " ").first ?? ""
    let sourceHash = shell("dd if=\(source.rawDevicePath) bs=16m status=none 2>/dev/null | shasum -a 256")
        .output.components(separatedBy: " ").first ?? ""
    assert(sourceHash == gunzipHash, "Decompressed content matches source (gzip-compatible)")

    detachDisk(source)
    print()
}

// MARK: - Cleanup

print("--- Cleanup ---")
// Detach any remaining disks
for disk in createdDisks {
    _ = shell("hdiutil detach \(disk.devicePath) -force 2>/dev/null")
}
try? fm.removeItem(at: testDir)
print("Cleaned up test directory.\n")

// MARK: - Results

print("=== Results: \(passed) passed, \(failed) failed ===")
exit(failed > 0 ? 1 : 0)
