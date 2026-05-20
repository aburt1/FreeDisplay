import Foundation
import CoreGraphics

/// Tells macOS to logically disconnect a display by wrapping the private
/// SkyLight Begin/ConfigureEnabled/Complete transaction (the same pattern
/// the public `CGBeginDisplayConfiguration` family uses, with an extra
/// "Enabled" step in the middle).
///
/// Once disabled the display vanishes from `CGGetOnlineDisplayList`,
/// WindowServer stops driving it, and the monitor enters self-sleep because
/// it sees no HPD signal.
///
/// Same mechanism Lunar and BetterDisplay use. Documented in
/// `trollzem/Lumen` (src/platform/macos/vd_helper.m). Stable since macOS 13.
@MainActor
final class DisplayConnectionService {
    static let shared = DisplayConnectionService()

    // CGDisplayConfigRef is the same opaque pointer the public API exposes —
    // SLS and CG share the type.
    private typealias SLSBeginFn = @convention(c) (UnsafeMutablePointer<CGDisplayConfigRef?>) -> Int32
    private typealias SLSConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
    private typealias SLSCompleteFn = @convention(c) (CGDisplayConfigRef?, UInt32) -> Int32

    private var slsBegin: SLSBeginFn?
    private var slsConfigureEnabled: SLSConfigureEnabledFn?
    private var slsComplete: SLSCompleteFn?
    private(set) var symbolsLoaded: Bool = false

    // CGConfigureOption raw values. We use ForSession so the change doesn't
    // survive a reboot (safety net if anything gets stuck).
    //   0 = kCGConfigureForAppOnly
    //   1 = kCGConfigureForSession
    //   2 = kCGConfigurePermanently
    private static let kConfigureForSession: UInt32 = 1

    // IDs the user explicitly disconnected, so DisplayManager can keep "ghost"
    // rows visible in the menu after the display vanishes from CGGetOnlineDisplayList.
    private(set) var disconnectedDisplayIDs: Set<CGDirectDisplayID> = []

    // UUIDs are persisted across app restarts; displayIDs are not (they can change).
    // On startup we look at currently-online displays and re-issue SLS Disable for
    // any whose UUID is in this set. kCGConfigureForSession ensures logout/reboot
    // wipes WindowServer's disable state, so this set is the source of truth.
    private static let kPersistedUUIDsKey = "fd.disconnectedDisplayUUIDs"
    private var persistedDisconnectedUUIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.kPersistedUUIDsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.kPersistedUUIDsKey)
        }
    }

    private init() {
        loadSymbols()
    }

    private func loadSymbols() {
        let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(skyLight, RTLD_LAZY) else {
            NSLog("[DisplayConnectionService] dlopen SkyLight failed: \(String(cString: dlerror()))")
            return
        }
        guard let beginSym = dlsym(handle, "SLSBeginDisplayConfiguration") else {
            NSLog("[DisplayConnectionService] missing symbol SLSBeginDisplayConfiguration")
            return
        }
        guard let configSym = dlsym(handle, "SLSConfigureDisplayEnabled") else {
            NSLog("[DisplayConnectionService] missing symbol SLSConfigureDisplayEnabled")
            return
        }
        guard let completeSym = dlsym(handle, "SLSCompleteDisplayConfiguration") else {
            NSLog("[DisplayConnectionService] missing symbol SLSCompleteDisplayConfiguration")
            return
        }
        slsBegin = unsafeBitCast(beginSym, to: SLSBeginFn.self)
        slsConfigureEnabled = unsafeBitCast(configSym, to: SLSConfigureEnabledFn.self)
        slsComplete = unsafeBitCast(completeSym, to: SLSCompleteFn.self)
        symbolsLoaded = true
        NSLog("[DisplayConnectionService] SLS symbols loaded successfully")
    }

    /// Returns true if the display was explicitly disconnected via this service.
    func wasDisconnectedByUser(_ displayID: CGDirectDisplayID) -> Bool {
        disconnectedDisplayIDs.contains(displayID)
    }

    /// Reapplies the persisted disconnect set to currently-online displays.
    /// Called once after DisplayManager populates `displays` at app launch.
    ///
    /// Safety: refuse to auto-disconnect the currently-main display, even if it
    /// was disconnected last session. The setup may have changed — the user may
    /// have unplugged the previous main, leaving the previously-disconnected
    /// display now driving the menu bar. Auto-disconnecting it would leave them
    /// blind with no way to recover from the FreeDisplay menu. They can still
    /// toggle it off manually if that's really what they want.
    func reapplyPersistedDisconnects(for displays: [DisplayInfo]) async {
        let persisted = persistedDisconnectedUUIDs
        guard !persisted.isEmpty, symbolsLoaded else { return }
        for display in displays
        where !display.isBuiltin
           && !display.isMain
           && persisted.contains(display.displayUUID)
        {
            NSLog("[DisplayConnectionService] restoring persisted disconnect for \(display.name) (\(display.displayUUID))")
            // persist:false because the UUID is already in the persisted set.
            _ = await setConnected(false, for: display, persist: false)
        }
    }

    /// Sets the WindowServer-visible connection state for the given display.
    /// Built-in displays are rejected — disabling the panel that hosts the menu
    /// bar would leave the user with no way to recover.
    @discardableResult
    func setConnected(_ connected: Bool, for display: DisplayInfo, persist: Bool = true) async -> Bool {
        guard !display.isBuiltin else {
            NSLog("[DisplayConnectionService] refusing to disable built-in display")
            return false
        }
        guard symbolsLoaded,
              let begin = slsBegin,
              let configure = slsConfigureEnabled,
              let complete = slsComplete else {
            NSLog("[DisplayConnectionService] SLS unavailable on this macOS")
            return false
        }

        display.isTogglingConnection = true
        defer { display.isTogglingConnection = false }

        var config: CGDisplayConfigRef?
        let beginResult = begin(&config)
        guard beginResult == 0, config != nil else {
            NSLog("[DisplayConnectionService] SLSBeginDisplayConfiguration failed (\(beginResult))")
            return false
        }

        let configureResult = configure(config, display.displayID, connected)
        NSLog("[DisplayConnectionService] SLSConfigureDisplayEnabled(display=\(display.displayID), enabled=\(connected)) → \(configureResult)")
        guard configureResult == 0 else {
            _ = complete(config, 0) // commit-as-app-only effectively aborts
            return false
        }

        let completeResult = complete(config, Self.kConfigureForSession)
        let success = (completeResult == 0)
        NSLog("[DisplayConnectionService] SLSCompleteDisplayConfiguration → \(completeResult) (\(success ? "OK" : "FAIL"))")

        if success {
            display.isDisconnected = !connected
            let uuid = display.displayUUID
            if connected {
                disconnectedDisplayIDs.remove(display.displayID)
                if persist {
                    var uuids = persistedDisconnectedUUIDs
                    uuids.remove(uuid)
                    persistedDisconnectedUUIDs = uuids
                }
                // After SLS re-enables a display, WindowServer often picks a default
                // mode instead of restoring the user's previous one. Reapply the saved
                // resolution / brightness / gamma so it looks like nothing happened.
                let displayID = display.displayID
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    ResolutionService.shared.reapplySavedModeIfNeeded(for: displayID)
                    BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                    GammaService.shared.reapplyIfNeeded(for: displayID)
                }
            } else {
                disconnectedDisplayIDs.insert(display.displayID)
                if persist {
                    var uuids = persistedDisconnectedUUIDs
                    uuids.insert(uuid)
                    persistedDisconnectedUUIDs = uuids
                }
            }
        }
        return success
    }
}
