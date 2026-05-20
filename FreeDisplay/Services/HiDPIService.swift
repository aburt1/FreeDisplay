import Foundation
import CoreGraphics
import IOKit

@MainActor
final class HiDPIService: @unchecked Sendable {
    static let shared = HiDPIService()
    private init() {}

    private var refreshTask: Task<Void, Never>?

    private let overridesBase = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides")

    // MARK: - Public API

    /// Checks whether HiDPI is enabled for the given display via plist override.
    func isHiDPIEnabled(for displayID: CGDirectDisplayID, vendor: UInt32, product: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: overridePlistURL(vendor: vendor, product: product).path)
    }

    /// Checks whether HiDPI is enabled for the given display via plist override only.
    func isHiDPIEnabled(vendor: UInt32, product: UInt32) -> Bool {
        let plistURL = overridePlistURL(vendor: vendor, product: product)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Enables HiDPI for an external display via plist override.
    /// Requires display reconnect (or reboot) to apply.
    ///
    /// Returns nil on success, or an error string on failure.
    func enableHiDPI(for displayID: CGDirectDisplayID,
                     vendor: UInt32,
                     product: UInt32,
                     nativeWidth: Int,
                     nativeHeight: Int) async -> String? {
        return enableHiDPIPlist(vendor: vendor, product: product,
                                nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Legacy single-path enable (plist only).
    func enableHiDPI(vendor: UInt32, product: UInt32, nativeWidth: Int, nativeHeight: Int) -> String? {
        enableHiDPIPlist(vendor: vendor, product: product,
                         nativeWidth: nativeWidth, nativeHeight: nativeHeight)
    }

    /// Disables HiDPI for an external display by removing the plist override.
    func disableHiDPI(for displayID: CGDirectDisplayID,
                      vendor: UInt32,
                      product: UInt32) -> String? {
        return disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Legacy single-path disable (plist only).
    func disableHiDPI(vendor: UInt32, product: UInt32) -> String? {
        disableHiDPIPlist(vendor: vendor, product: product)
    }

    /// Refreshes availableModes on the given DisplayInfo after enabling HiDPI.
    func refreshModes(for display: DisplayInfo) {
        refreshTask?.cancel()
        let physicalID = display.displayID

        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            async let modes = Task.detached(priority: .userInitiated) {
                DisplayMode.availableModes(for: physicalID)
            }.value
            async let current = Task.detached(priority: .userInitiated) {
                DisplayMode.currentMode(for: physicalID)
            }.value
            display.availableModes = await modes
            display.currentDisplayMode = await current
        }
    }

    // MARK: - Plist Override

    private func enableHiDPIPlist(vendor: UInt32, product: UInt32,
                                   nativeWidth: Int, nativeHeight: Int) -> String? {
        let dirPath = overrideDir(vendor: vendor).path
        let plistPath = overridePlistURL(vendor: vendor, product: product).path

        let scaledModes = generateScaledModes(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
        let plist: [String: Any] = [
            "scale-resolutions": scaledModes
        ]

        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
            return "Failed to generate Plist data"
        }

        // Write to a temp file first, then use privileged helper to move it
        let tmpPath = NSTemporaryDirectory() + "fd_hidpi_override.plist"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
        } catch {
            return "Failed to write temporary file: \(error.localizedDescription)"
        }

        // Use AppleScript to get admin privileges for writing to /Library/Displays/.
        // Paths are shell-escaped to avoid injection through quotes or backslashes.
        let cmd = "mkdir -p \(Self.shellEscape(dirPath)) && cp \(Self.shellEscape(tmpPath)) \(Self.shellEscape(plistPath))"
        if let err = executePrivilegedCommand(cmd) {
            return err
        }

        // Clean up temp file
        try? FileManager.default.removeItem(atPath: tmpPath)

        // Attempt to trigger display mode re-enumeration via IOServiceRequestProbe
        triggerDisplayReenumeration(vendor: vendor, product: product)

        return nil
    }

    private func disableHiDPIPlist(vendor: UInt32, product: UInt32) -> String? {
        let plistPath = overridePlistURL(vendor: vendor, product: product).path
        guard FileManager.default.fileExists(atPath: plistPath) else { return nil }

        if let err = executePrivilegedCommand("rm -f \(Self.shellEscape(plistPath))") {
            return err
        }
        return nil
    }

    // MARK: - Helpers

    /// Wraps `s` in single quotes for safe inclusion in a `sh` command line.
    /// Single-quoted strings in sh disable everything except `'`, so we close
    /// the quote, emit an escaped quote, and reopen — the standard recipe.
    /// All callers passing paths or untrusted data to `executePrivilegedCommand`
    /// MUST run them through this helper first.
    static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use as a literal inside an AppleScript double-quoted
    /// string. `\` must come first, then `"`.
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Executes a shell command with administrator privileges via AppleScript.
    /// The command is AppleScript-escaped here, but callers are responsible for
    /// shell-escaping any arguments inside the command (use `shellEscape`).
    /// Returns nil on success, or an error message on failure.
    private func executePrivilegedCommand(_ command: String) -> String? {
        // The command becomes the body of an AppleScript double-quoted string, so
        // any `"` or `\` inside must be escaped at the AppleScript level. Without
        // this, a `"` in the command would terminate the literal and turn the
        // remainder into arbitrary AppleScript executing as root.
        let escapedCommand = Self.appleScriptEscape(command)
        let script = """
            do shell script "\(escapedCommand)" with administrator privileges
            """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return "Failed to create AppleScript"
        }
        appleScript.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            if msg.contains("canceled") || msg.contains("Cancel") {
                return "User cancelled authorization"
            }
            return "Administrator authorization failed: \(msg)"
        }
        return nil
    }

    private func triggerDisplayReenumeration(vendor: UInt32, product: UInt32) {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            guard let cfDict = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() else {
                continue
            }
            let dict = cfDict as NSDictionary

            let serviceVendor: UInt32
            let serviceProduct: UInt32

            if let v = dict["DisplayVendorID"] as? UInt32 {
                serviceVendor = v
            } else if let v = dict["DisplayVendorID"] as? Int {
                serviceVendor = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
            } else { continue }

            if let p = dict["DisplayProductID"] as? UInt32 {
                serviceProduct = p
            } else if let p = dict["DisplayProductID"] as? Int {
                serviceProduct = UInt32(bitPattern: Int32(truncatingIfNeeded: p))
            } else { continue }

            guard serviceVendor == vendor && serviceProduct == product else { continue }

            IOServiceRequestProbe(service, 0)
            break
        }
    }

    private func overrideDir(vendor: UInt32) -> URL {
        overridesBase
            .appendingPathComponent(String(format: "DisplayVendorID-%x", vendor))
    }

    private func overridePlistURL(vendor: UInt32, product: UInt32) -> URL {
        overrideDir(vendor: vendor)
            .appendingPathComponent(String(format: "DisplayProductID-%x", product))
    }

    private func generateScaledModes(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        // Generate HiDPI modes: each entry is 8 bytes big-endian (backingW, backingH)
        // For a 2560×1440 display, we want:
        //   1920×1080 HiDPI (backing 3840×2160)
        //   1600×900  HiDPI (backing 3200×1800)
        //   1280×720  HiDPI (backing 2560×1440)
        //   native as HiDPI (backing 5120×2880)
        var resolutions: [(Int, Int)] = []

        // Native resolution as HiDPI (2x backing)
        resolutions.append((nativeWidth * 2, nativeHeight * 2))

        // Scaled HiDPI modes
        let scales: [Double] = [0.75, 0.625, 0.5]
        for scale in scales {
            let logicalW = Int((Double(nativeWidth) * scale).rounded()) & ~1
            let logicalH = Int((Double(nativeHeight) * scale).rounded()) & ~1
            guard logicalW >= 800, logicalH >= 600 else { continue }
            resolutions.append((logicalW * 2, logicalH * 2))
        }

        return resolutions.map { (backingW, backingH) in
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes[0] = UInt8((backingW >> 24) & 0xFF)
            bytes[1] = UInt8((backingW >> 16) & 0xFF)
            bytes[2] = UInt8((backingW >> 8) & 0xFF)
            bytes[3] = UInt8(backingW & 0xFF)
            bytes[4] = UInt8((backingH >> 24) & 0xFF)
            bytes[5] = UInt8((backingH >> 16) & 0xFF)
            bytes[6] = UInt8((backingH >> 8) & 0xFF)
            bytes[7] = UInt8(backingH & 0xFF)
            return Data(bytes)
        }
    }
}
