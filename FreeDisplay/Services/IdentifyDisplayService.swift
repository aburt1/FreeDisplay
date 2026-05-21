import AppKit
import CoreGraphics

/// Briefly flashes a translucent accent-colored overlay on a specific physical
/// display so the user can map a menu row to the corresponding screen.
///
/// Triggered on row hover (after a short debounce so brushing past doesn't fire).
/// The overlay is a borderless `NSWindow` at status-bar window level, click-through,
/// and self-dismisses after the flash duration.
@MainActor
final class IdentifyDisplayService {
    static let shared = IdentifyDisplayService()
    private init() {}

    private var activeOverlays: [CGDirectDisplayID: NSWindow] = [:]
    private var hoverTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]

    /// Schedules a flash if the row stays hovered for ~280ms. Brushing past
    /// the row (hover < 280ms) does not trigger anything.
    func scheduleFlash(for display: DisplayInfo) {
        cancelScheduled(for: display.displayID)
        hoverTasks[display.displayID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            self?.flash(for: display)
        }
    }

    /// Called on hover-exit. Cancels a pending flash; does NOT interrupt an
    /// already-running flash (those self-complete in ~600ms).
    func cancelScheduled(for displayID: CGDirectDisplayID) {
        hoverTasks[displayID]?.cancel()
        hoverTasks[displayID] = nil
    }

    /// Shows an accent-colored overlay on the physical display, then fades out.
    func flash(for display: DisplayInfo) {
        let displayID = display.displayID

        // Re-show on rapid re-hover — replace the existing overlay so it
        // doesn't accumulate or fight an in-progress fade.
        activeOverlays[displayID]?.close()

        // Need the actual NSScreen for the displayID to anchor the window.
        // `NSScreenNumber` arrives as an NSNumber; casting directly to
        // `CGDirectDisplayID` (a UInt32 typealias) silently fails on some
        // macOS versions for non-main screens, so go through NSNumber.
        guard let screen = NSScreen.screens.first(where: { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(n.uint32Value) == displayID
        }) else {
            let available = NSScreen.screens.compactMap {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }
            NSLog("[IdentifyDisplayService] no NSScreen for displayID=\(displayID) (name=\(display.name)) — available IDs: \(available)")
            return
        }

        let rect = screen.frame

        // Known macOS bug: NSWindow.init(contentRect:...:screen:) does not honor
        // the contentRect correctly on rotated displays — the window ends up at
        // the right size but the wrong position (often clipped off-screen).
        // Workaround: initialise with a placeholder rect at origin, then move it
        // into place with setFrame after creation.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: rect.width, height: rect.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(rect, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        // Just-below-shielding: highest practical level that still respects the
        // login window / screensaver. Higher than `.statusBar` (25) and even
        // `.screenSaver` (1000) — necessary for rotated displays where macOS
        // can push our overlay below other compositor layers.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false

        // Content: a thick rounded-rect ring in the display's accent color +
        // a centered name label. We avoid a solid full-screen fill because
        // it's visually heavy and disrupts whatever the user is doing.
        let accent = DisplayAccent.nsColor(for: display.displayUUID)
        let content = NSView(frame: rect)
        content.wantsLayer = true
        let layer = CALayer()
        layer.frame = content.bounds
        layer.borderColor = accent.withAlphaComponent(0.9).cgColor
        layer.borderWidth = 14
        layer.cornerRadius = 24
        layer.backgroundColor = accent.withAlphaComponent(0.08).cgColor
        content.layer = layer

        // Display name in the centre, oversized.
        let label = NSTextField(labelWithString: display.name)
        label.font = NSFont.systemFont(ofSize: 96, weight: .heavy)
        label.textColor = .white
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.55)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        window.contentView = content
        window.alphaValue = 0
        window.orderFrontRegardless()

        activeOverlays[displayID] = window

        // Fade in → hold → fade out → close.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 1.0
        } completionHandler: {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    window.animator().alphaValue = 0
                } completionHandler: {
                    window.close()
                    self?.activeOverlays[displayID] = nil
                }
            }
        }
    }
}
