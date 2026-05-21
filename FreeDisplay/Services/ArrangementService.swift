import Foundation
import CoreGraphics

/// Service for reading and setting display positions in the global coordinate space.
/// On macOS, the display whose bounds contain origin (0, 0) is the main display
/// (the one that shows the Dock and menu bar).
@MainActor
class ArrangementService {
    static let shared = ArrangementService()
    private init() {}

    /// Moves the given display to the specified position in the global coordinate space.
    /// The entire Begin→Origin→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setPosition(x: Int, y: Int, for displayID: CGDirectDisplayID) async -> Bool {
        await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            CGConfigureDisplayOrigin(cfg, displayID, Int32(x), Int32(y))
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }

    /// Aligns every non-main display's vertical center to match the main display's
    /// vertical center, in one atomic Begin→Origin→Complete transaction.
    ///
    /// This is the operation that makes cursor movement between side-by-side
    /// displays *fluid* — when centers are aligned, moving the cursor off the
    /// right edge of display A at any height lands on display B at the same
    /// proportional height, with no abrupt vertical jump.
    @discardableResult
    func alignVerticalCenters(among displays: [DisplayInfo]) async -> Bool {
        guard let main = displays.first(where: { $0.isMain }) else { return false }
        let targetCenterY = main.bounds.midY

        // Capture value types only — pointers and reference types can't cross
        // the @Sendable closure boundary.
        let updates: [(id: CGDirectDisplayID, x: Int32, y: Int32)] = displays
            .filter { !$0.isMain }
            .map { d in
                let newY = targetCenterY - d.bounds.height / 2
                return (id: d.displayID, x: Int32(d.bounds.origin.x), y: Int32(newY))
            }

        guard !updates.isEmpty else { return true }   // nothing to do

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            for u in updates {
                CGConfigureDisplayOrigin(cfg, u.id, u.x, u.y)
            }
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }

    /// Makes the target display the main display by moving it to origin (0, 0).
    /// Moves the current main display to the position previously occupied by the target.
    /// The entire Begin→Origin→Complete transaction runs inside `CGHelpers.runWithTimeout`
    /// so `CGCompleteDisplayConfiguration` cannot block indefinitely on WindowServer IPC.
    /// - Returns: true if the configuration was applied successfully.
    @discardableResult
    func setAsMainDisplay(_ targetID: CGDirectDisplayID, among displays: [DisplayInfo]) async -> Bool {
        guard let target = displays.first(where: { $0.displayID == targetID }),
              let currentMain = displays.first(where: { $0.isMain }),
              currentMain.displayID != targetID else {
            return false
        }

        // Capture value types only — no OpaquePointer crossing the @Sendable boundary.
        let targetOriginX = Int32(target.bounds.origin.x)
        let targetOriginY = Int32(target.bounds.origin.y)
        let currentMainID = currentMain.displayID

        return await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }

            // Move target to origin → it becomes the new main display
            CGConfigureDisplayOrigin(cfg, targetID, 0, 0)

            // Move old main to where the target was.
            CGConfigureDisplayOrigin(cfg, currentMainID, targetOriginX, targetOriginY)

            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }
    }
}
