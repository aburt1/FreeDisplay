import Foundation
import CoreGraphics
import IOKit
import AppKit

@MainActor
class DisplayInfo: ObservableObject, Identifiable {
    nonisolated var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    @Published var name: String
    @Published var isBuiltin: Bool
    @Published var isMain: Bool
    @Published var isOnline: Bool
    @Published var isEnabled: Bool
    @Published var bounds: CGRect
    @Published var pixelWidth: Int
    @Published var pixelHeight: Int
    @Published var brightness: Double
    @Published var availableModes: [DisplayMode]
    @Published var currentDisplayMode: DisplayMode?
    @Published var ddcValues: [UInt8: UInt16?] = [:]
    /// True when the user has disconnected this display via the toggle.
    /// macOS will see the display as offline; the panel itself enters
    /// self-sleep because it stops receiving an HPD signal.
    @Published var isDisconnected: Bool = false
    /// True while a connect/disconnect call is in flight.
    @Published var isTogglingConnection: Bool = false
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32

    /// A stable identifier for the physical display that persists across sleep/wake
    /// even if macOS reassigns the CGDirectDisplayID.
    var displayUUID: String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
           let uuidStr = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) {
            return uuidStr as String
        }
        // Fallback: vendor+model+serial hash is more stable than raw displayID
        return "v\(vendorNumber)-m\(modelNumber)-s\(serialNumber)"
    }

    /// The native (highest non-HiDPI) resolution, used for HiDPI enablement and presets.
    var nativeResolution: (width: Int, height: Int) {
        let nativeMode = availableModes
            .filter { !$0.isHiDPI }
            .max(by: { ($0.width * $0.height) < ($1.width * $1.height) })
        return (nativeMode?.width ?? pixelWidth, nativeMode?.height ?? pixelHeight)
    }

    /// Same as `nativeResolution` but un-rotated to match the framebuffer the
    /// GPU actually scans out. `CGDisplayCopyAllDisplayModes` reports modes in
    /// the *current* rotated orientation (e.g. a 2560×1080 ultrawide rotated
    /// 90° reports 1080×2560), but the HiDPI plist override in
    /// `/Library/Displays/.../Overrides/` is keyed on the *unrotated* EDID
    /// framebuffer — rotation is a WindowServer composition transform that
    /// happens after the buffer. Passing rotated dimensions into the override
    /// silently no-ops (the framebuffer never runs portrait) and triggers the
    /// double-rotation bug documented in waydabber/BetterDisplay#4672.
    var nativeResolutionUnrotated: (width: Int, height: Int) {
        let (w, h) = nativeResolution
        let rot = Int(CGDisplayRotation(displayID).rounded()) % 180
        return rot == 0 ? (w, h) : (h, w)
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        let builtin = CGDisplayIsBuiltin(displayID) != 0
        self.isBuiltin = builtin
        self.isMain = CGDisplayIsMain(displayID) != 0
        self.isOnline = CGDisplayIsOnline(displayID) != 0
        self.isEnabled = CGDisplayIsActive(displayID) != 0
        self.bounds = CGDisplayBounds(displayID)
        self.pixelWidth = CGDisplayPixelsWide(displayID)
        self.pixelHeight = CGDisplayPixelsHigh(displayID)
        // Use persisted brightness as the initial value if available, otherwise 50.0.
        // BrightnessService will overwrite this with the real hardware value once probed.
        self.brightness = SettingsService.shared.brightness(for: displayID) ?? 50.0
        self.availableModes = []
        self.currentDisplayMode = DisplayMode.currentMode(for: displayID)
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        self.vendorNumber = vendor
        self.modelNumber = model
        self.serialNumber = CGDisplaySerialNumber(displayID)

        if builtin {
            self.name = "Built-in Display"
        } else {
            self.name = NSScreen.screen(for: displayID)?.localizedName ?? "Display \(displayID)"
        }

    }

    func loadDetails() async {
        let displayID = self.displayID

        let modes = await Task.detached(priority: .userInitiated) {
            DisplayMode.availableModes(for: displayID)
        }.value

        self.availableModes = modes
    }
}
