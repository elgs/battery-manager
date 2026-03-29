// Minimal SMC writer — no SwiftUI/AppKit to avoid WindowServer side effects.
// This binary is invoked as root via sudo to set SMC charging keys.

import Foundation
import IOKit

// MARK: - SMC Data Types (duplicated to avoid cross-target dependency on AppKit)

struct SMCKeyData {
    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers: Vers = Vers()
    var pLimitData: PLimitData = PLimitData()
    var keyInfo: KeyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private let smcCmdWriteBytes: UInt8 = 6
private let smcCmdReadKeyInfo: UInt8 = 9

// MARK: - Minimal SMC access

func smcOpen() -> io_connect_t? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("AppleSMCKeysEndpoint"))
    let svc = service != MACH_PORT_NULL ? service :
        IOServiceGetMatchingService(kIOMainPortDefault,
            IOServiceMatching("AppleSMC"))
    guard svc != MACH_PORT_NULL else { return nil }
    defer { IOObjectRelease(svc) }

    var conn: io_connect_t = 0
    let result = IOServiceOpen(svc, mach_task_self_, 0, &conn)
    guard result == kIOReturnSuccess else { return nil }
    return conn
}

func fourCharCode(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for char in str.utf8.prefix(4) {
        result = (result << 8) | UInt32(char)
    }
    return result
}

func smcWriteKey(_ conn: io_connect_t, _ key: String, _ bytes: [UInt8]) -> Bool {
    let smcKey = fourCharCode(key)
    var inputStruct = SMCKeyData()
    var outputStruct = SMCKeyData()
    inputStruct.key = smcKey
    inputStruct.data8 = smcCmdReadKeyInfo
    let inputSize = MemoryLayout<SMCKeyData>.size
    var outputSize = MemoryLayout<SMCKeyData>.size

    var result = IOConnectCallStructMethod(conn, 2,
        &inputStruct, inputSize, &outputStruct, &outputSize)
    guard result == kIOReturnSuccess else { return false }

    let dataType = outputStruct.keyInfo.dataType
    let dataSize = outputStruct.keyInfo.dataSize

    inputStruct = SMCKeyData()
    outputStruct = SMCKeyData()
    inputStruct.key = smcKey
    inputStruct.keyInfo.dataSize = dataSize
    inputStruct.keyInfo.dataType = dataType
    inputStruct.data8 = smcCmdWriteBytes

    withUnsafeMutablePointer(to: &inputStruct.bytes) { ptr in
        let raw = UnsafeMutableRawPointer(ptr)
        for (i, byte) in bytes.prefix(Int(dataSize)).enumerated() {
            raw.storeBytes(of: byte, toByteOffset: i, as: UInt8.self)
        }
    }

    outputSize = MemoryLayout<SMCKeyData>.size
    result = IOConnectCallStructMethod(conn, 2,
        &inputStruct, inputSize, &outputStruct, &outputSize)
    return result == kIOReturnSuccess
}

// MARK: - Sleep control

/// Read the current `sleep` value from pmset.
func readPmsetSleep() -> Int? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    task.arguments = ["-g"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("sleep") && !trimmed.hasPrefix("sleepimage") && !trimmed.hasPrefix("disksleep") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let val = Int(parts[1]) {
                    return val
                }
            }
        }
    } catch {}
    return nil
}

/// Path to store the original sleep value for restoration.
let savedSleepPath = "/tmp/.battery_manager_saved_sleep"

/// Prevent or restore system/clamshell sleep using pmset. Requires root.
@discardableResult
func setDischargeSleepPrevention(enabled: Bool) -> Bool {
    if enabled {
        // Save original sleep value before overriding
        if let original = readPmsetSleep() {
            try? "\(original)".write(toFile: savedSleepPath, atomically: true, encoding: .utf8)
        }
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    if enabled {
        task.arguments = ["-a", "sleep", "0", "disablesleep", "1"]
    } else {
        // Restore original sleep value
        let originalSleep: String
        if let saved = try? String(contentsOfFile: savedSleepPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            originalSleep = saved
            try? FileManager.default.removeItem(atPath: savedSleepPath)
        } else {
            originalSleep = "1" // safe default
        }
        task.arguments = ["-a", "sleep", originalSleep, "disablesleep", "0"]
    }
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        fputs("WARNING: Failed to run pmset: \(error.localizedDescription)\n", stderr)
        return false
    }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: smc-writer inhibit|allow|discharge:pid|nodischarge\n", stderr)
    exit(1)
}

let action = CommandLine.arguments[1]

// "discharge:PID" — set sleep prevention, write CHIE, spawn watchdog daemon, exit.
if action.hasPrefix("discharge:") {
    guard let appPID = Int32(action.dropFirst("discharge:".count)) else {
        fputs("ERROR: invalid PID in discharge command\n", stderr)
        exit(1)
    }

    guard let conn = smcOpen() else {
        fputs("ERROR: Could not open SMC connection\n", stderr)
        exit(1)
    }

    _ = setDischargeSleepPrevention(enabled: true)

    let chieValue: [UInt8] = [0x08]
    guard smcWriteKey(conn, "CHIE", chieValue) else {
        _ = setDischargeSleepPrevention(enabled: false)
        IOServiceClose(conn)
        fputs("ERROR: SMC write failed for CHIE\n", stderr)
        exit(2)
    }
    IOServiceClose(conn)

    // Spawn a watchdog daemon as a separate process via posix_spawn.
    // The daemon monitors the app PID and cleans up if it dies.
    // Using posix_spawn (not fork) because Swift runtime is not fork-safe.
    let execPath = CommandLine.arguments[0]
    var spawnPid: pid_t = 0
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

    let arg0 = strdup(execPath)!
    let arg1 = strdup("watchdog:\(appPID)")!
    var args: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
    let spawnResult = posix_spawn(&spawnPid, execPath, &fileActions, nil, &args, nil)
    posix_spawn_file_actions_destroy(&fileActions)
    free(arg0)
    free(arg1)

    if spawnResult != 0 {
        fputs("WARNING: Failed to spawn watchdog (errno \(spawnResult))\n", stderr)
    }

    print("OK: active discharge enabled")
    exit(0)
}

// "watchdog:PID" — monitor app PID, clean up CHIE + sleep when app dies.
// Spawned by the discharge command as a detached daemon.
if action.hasPrefix("watchdog:") {
    guard let appPID = Int32(action.dropFirst("watchdog:".count)) else {
        _exit(1)
    }

    // Poll every 2s
    while true {
        sleep(2)
        if kill(appPID, 0) != 0 {
            // App is gone — clean up
            if let conn = smcOpen() {
                _ = smcWriteKey(conn, "CHIE", [0x00])
                IOServiceClose(conn)
            }
            _ = setDischargeSleepPrevention(enabled: false)
            _exit(0)
        }
    }
}

// One-shot commands
let validActions: Set<String> = ["inhibit", "allow", "nodischarge"]
guard validActions.contains(action) else {
    fputs("Usage: smc-writer inhibit|allow|discharge:pid|nodischarge\n", stderr)
    exit(1)
}

guard let conn = smcOpen() else {
    fputs("ERROR: Could not open SMC connection\n", stderr)
    exit(1)
}
defer { IOServiceClose(conn) }

switch action {
case "inhibit":
    let chteValue: [UInt8] = [0x01, 0x00, 0x00, 0x00]
    if smcWriteKey(conn, "CHTE", chteValue) {
        print("OK: charging inhibited")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHTE\n", stderr)
        exit(2)
    }

case "allow":
    let chteValue: [UInt8] = [0x00, 0x00, 0x00, 0x00]
    if smcWriteKey(conn, "CHTE", chteValue) {
        print("OK: charging allowed")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHTE\n", stderr)
        exit(2)
    }

case "nodischarge":
    // Clears CHIE and restores sleep. Used for graceful stop (app calls this
    // before killing the daemon) and launch cleanup.
    let chieValue: [UInt8] = [0x00]
    if smcWriteKey(conn, "CHIE", chieValue) {
        _ = setDischargeSleepPrevention(enabled: false)
        print("OK: active discharge disabled")
        exit(0)
    } else {
        fputs("ERROR: SMC write failed for CHIE\n", stderr)
        exit(2)
    }

default:
    fatalError("unexpected action: \(action)")
}
