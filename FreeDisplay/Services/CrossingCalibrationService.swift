import AppKit
import SwiftUI
import CoreGraphics
import Combine

/// Interactive calibration: the user draws a single continuous line from one
/// display to another. Where the line starts on display A defines A's crossing
/// point; where it ends on display B defines B's crossing point. On mouse-up,
/// we align those two points to the same global Y so the cursor flows smoothly
/// at exactly those heights.
///
/// Why this beats geometric center-align: physical monitors sit at different
/// heights, angles, and viewing distances. The "natural" crossing point is
/// wherever the user's eye expects it, which may be 1/3 up on the tall monitor
/// and 2/3 up on the wide one. Drawing the line *across* both displays captures
/// that intention with a single gesture — start where it feels right on A,
/// end where it feels right on B, and the gap between is the misalignment we
/// remove.
@MainActor
final class CrossingCalibrationService: ObservableObject {
    static let shared = CrossingCalibrationService()
    private init() {}

    /// Where the user pressed the mouse down. Drives the "start marker" on the
    /// source display.
    struct DragPoint: Equatable {
        let displayID: CGDirectDisplayID
        let localY: CGFloat            // top-down within that display
    }

    @Published private(set) var dragStart: DragPoint? = nil
    @Published private(set) var dragCurrent: DragPoint? = nil
    @Published private(set) var isDragging: Bool = false
    /// True iff calibration overlays are currently visible.
    @Published private(set) var isActive: Bool = false

    /// Snapshot of displays being calibrated (used by overlay views).
    private(set) var calibratingDisplays: [DisplayInfo] = []

    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    private var mouseMonitors: [Any] = []

    // MARK: - Entry / exit

    func begin(displays: [DisplayInfo]) {
        guard !isActive, displays.count >= 2 else { return }
        calibratingDisplays = displays
        dragStart = nil
        dragCurrent = nil
        isDragging = false

        for display in displays {
            guard let screen = screen(for: display.displayID) else { continue }
            let win = makeOverlay(for: display, screen: screen)
            overlayWindows[display.displayID] = win
            win.orderFrontRegardless()
        }
        installMouseMonitors()
        isActive = true
    }

    func cancel() {
        teardown()
    }

    // MARK: - Mouse handling

    private func installMouseMonitors() {
        // Local monitor catches events on our overlay windows; global monitor
        // catches events outside our windows so a drag that crosses screens
        // is tracked even when the cursor isn't over an overlay (rare).
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in self.handle(event) }
            return event
        }
        if let local { mouseMonitors.append(local) }

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handle(event) }
        }
        if let global { mouseMonitors.append(global) }

        // Esc to cancel mid-drag.
        let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {     // .escape
                Task { @MainActor in self?.cancel() }
                return nil
            }
            return event
        }
        if let key { mouseMonitors.append(key) }
    }

    private func removeMouseMonitors() {
        for m in mouseMonitors { NSEvent.removeMonitor(m) }
        mouseMonitors.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard let point = currentDragPoint() else { return }
            dragStart = point
            dragCurrent = point
            isDragging = true
        case .leftMouseDragged:
            guard isDragging, let point = currentDragPoint() else { return }
            dragCurrent = point
        case .leftMouseUp:
            guard isDragging else { return }
            isDragging = false
            let start = dragStart
            let end = dragCurrent
            // If the drag crossed displays, apply. Otherwise reset and let the
            // user try again — calibration needs two displays' worth of data.
            if let s = start, let e = end, s.displayID != e.displayID {
                Task { await apply(start: s, end: e) }
            } else {
                dragStart = nil
                dragCurrent = nil
            }
        default:
            break
        }
    }

    /// Returns a `DragPoint` for wherever the cursor is right now, or nil if
    /// the cursor isn't on any known screen.
    private func currentDragPoint() -> DragPoint? {
        let global = NSEvent.mouseLocation   // AppKit coords, Y-up
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(global) }) else { return nil }
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(n.uint32Value)
        // Convert to top-down local Y within the screen for ergonomic UI math.
        let localY = screen.frame.maxY - global.y
        return DragPoint(displayID: displayID, localY: localY)
    }

    // MARK: - Apply

    private func apply(start: DragPoint, end: DragPoint) async {
        let displays = calibratingDisplays
        guard let startDisplay = displays.first(where: { $0.displayID == start.displayID }),
              let endDisplay = displays.first(where: { $0.displayID == end.displayID }) else {
            teardown()
            return
        }

        // Pick an anchor — the display that does NOT move. If one of the two
        // points is on the main display, anchor that. Otherwise anchor the
        // start display so the user's first gesture point stays where it was.
        let mainID = displays.first(where: { $0.isMain })?.displayID
        let (anchor, mover): (DragPoint, DragPoint)
        let (anchorDisp, moverDisp): (DisplayInfo, DisplayInfo)
        if mainID == start.displayID {
            anchor = start; mover = end
            anchorDisp = startDisplay; moverDisp = endDisplay
        } else if mainID == end.displayID {
            anchor = end; mover = start
            anchorDisp = endDisplay; moverDisp = startDisplay
        } else {
            anchor = start; mover = end
            anchorDisp = startDisplay; moverDisp = endDisplay
        }

        let anchorGlobalY = anchorDisp.bounds.origin.y + anchor.localY
        // We want: mover.bounds.origin.y + mover.localY == anchorGlobalY.
        // Capture value types up front — @MainActor-isolated DisplayInfo refs
        // can't cross the @Sendable boundary into runWithTimeout's closure.
        let moverID = moverDisp.displayID
        let moverX = Int32(moverDisp.bounds.origin.x)
        let newMoverOriginY = Int32(anchorGlobalY - mover.localY)

        _ = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success,
                  let cfg = config else { return false }
            CGConfigureDisplayOrigin(cfg, moverID, moverX, newMoverOriginY)
            let result = CGCompleteDisplayConfiguration(cfg, .forSession)
            if result != .success {
                CGCancelDisplayConfiguration(cfg)
                return false
            }
            return true
        }

        teardown()
    }

    // MARK: - Teardown / helpers

    private func teardown() {
        removeMouseMonitors()
        for (_, win) in overlayWindows { win.close() }
        overlayWindows.removeAll()
        calibratingDisplays = []
        dragStart = nil
        dragCurrent = nil
        isDragging = false
        isActive = false
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(n.uint32Value) == displayID
        }
    }

    private func makeOverlay(for display: DisplayInfo, screen: NSScreen) -> NSWindow {
        let frame = screen.frame
        // Rotated-display NSWindow positioning workaround — init with placeholder
        // rect, then setFrame after.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: frame.width, height: frame.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.32)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        window.ignoresMouseEvents = false       // we want clicks/drags here
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        let view = CalibrationOverlayView(display: display)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        return window
    }
}

// MARK: - Overlay SwiftUI view

private struct CalibrationOverlayView: View {
    let display: DisplayInfo
    @ObservedObject private var svc = CrossingCalibrationService.shared

    /// Local Y of the start point if it lives on THIS display.
    private var startY: CGFloat? {
        svc.dragStart?.displayID == display.displayID ? svc.dragStart?.localY : nil
    }
    /// Local Y of the current cursor point if it's on THIS display.
    private var currentY: CGFloat? {
        svc.dragCurrent?.displayID == display.displayID ? svc.dragCurrent?.localY : nil
    }

    private var accent: Color { DisplayAccent.color(for: display.displayUUID) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Click-through transparent layout layer (the window itself is
                // tinted; the NSEvent monitor catches the mouse).
                Color.clear

                // Start marker — solid horizontal line + dot, persists for the
                // duration of the drag on whichever display the drag began on.
                if let y = startY {
                    line(at: y, color: accent.opacity(0.95), width: geo.size.width)
                    Circle()
                        .fill(accent)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                        .position(x: 28, y: y)
                }

                // Live cursor line — dashed accent line at the cursor's Y on
                // whichever display the cursor is currently on.
                if let y = currentY, svc.isDragging, y != startY {
                    line(at: y, color: accent.opacity(0.55), width: geo.size.width, dashed: true)
                }

                // Header text
                VStack(spacing: 6) {
                    Text(display.name)
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundColor(.white)

                    if svc.isDragging {
                        if svc.dragStart?.displayID == display.displayID {
                            Text("Now drag across to the other display")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.9))
                        } else if svc.dragCurrent?.displayID == display.displayID {
                            Text("Release here at the matching height")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.9))
                        }
                    } else {
                        Text("Click on one display, drag to the other,\nrelease at the matching crossing height.")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }

                    Text("Press Esc to cancel")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .padding(.top, 4)
                }
                .padding(.top, 56)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func line(at y: CGFloat, color: Color, width: CGFloat, dashed: Bool = false) -> some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(color, style: StrokeStyle(
            lineWidth: 2,
            lineCap: .round,
            dash: dashed ? [6, 6] : []
        ))
    }
}
