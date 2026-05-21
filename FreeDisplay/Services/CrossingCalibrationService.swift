import AppKit
import SwiftUI
import CoreGraphics
import Combine

/// Interactive calibration: the user drags a horizontal line on each display to
/// indicate where the cursor should naturally cross to/from the other displays.
/// On Apply, we move every non-main display so its marked line sits at the same
/// global Y as the main display's marked line — making cursor movement *fluid*
/// at the points the user actually cares about, not at the geometric center.
///
/// Why this beats geometric center-align: physical monitors sit at different
/// heights, angles, and viewing distances. The "natural" crossing point is
/// wherever the user's eye expects it, which may be 1/3 up on the tall monitor
/// and 2/3 up on the wide one. Calibration captures that subjective truth.
@MainActor
final class CrossingCalibrationService: ObservableObject {
    static let shared = CrossingCalibrationService()
    private init() {}

    /// Per-display line position as a 0..1 fraction of display height.
    /// Starts at 0.5 (center) for each display when calibration begins.
    @Published var lineFraction: [CGDirectDisplayID: CGFloat] = [:]

    /// Backing windows; one per display while calibration is running.
    private var overlayWindows: [CGDirectDisplayID: NSWindow] = [:]
    /// Used by the SwiftUI panel to know which display is "main" — its line
    /// position is the anchor every other display aligns against.
    private(set) var mainDisplayID: CGDirectDisplayID = 0

    /// True iff calibration overlays are currently visible.
    @Published private(set) var isActive: Bool = false

    /// Snapshot of display IDs being calibrated, in stable order for the SwiftUI panel.
    private(set) var calibratingDisplays: [DisplayInfo] = []

    // MARK: - Entry / exit

    /// Opens an overlay on every connected display. Call from a menu button.
    func begin(displays: [DisplayInfo]) {
        guard !isActive, displays.count >= 2 else { return }
        calibratingDisplays = displays
        mainDisplayID = displays.first(where: { $0.isMain })?.displayID ?? displays[0].displayID

        // Seed every line at vertical center.
        lineFraction = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, 0.5) })

        for display in displays {
            guard let screen = screen(for: display.displayID) else { continue }
            let win = makeOverlay(for: display, screen: screen)
            overlayWindows[display.displayID] = win
            win.orderFrontRegardless()
        }
        isActive = true
    }

    /// Closes overlays without changing display arrangement.
    func cancel() {
        teardown()
    }

    /// Computes new origin Y for every non-main display so its marked line ends
    /// at the same global Y as the main display's marked line, then applies the
    /// arrangement change atomically.
    func apply() async {
        guard isActive else { return }
        let displays = calibratingDisplays
        let fractions = lineFraction
        teardown()

        guard let main = displays.first(where: { $0.displayID == mainDisplayID }),
              let mainFrac = fractions[main.displayID] else { return }

        let mainGlobalY = main.bounds.origin.y + mainFrac * main.bounds.height

        let updates: [(id: CGDirectDisplayID, x: Int32, y: Int32)] = displays
            .filter { $0.displayID != main.displayID }
            .compactMap { d in
                guard let frac = fractions[d.displayID] else { return nil }
                let newY = mainGlobalY - frac * d.bounds.height
                return (id: d.displayID, x: Int32(d.bounds.origin.x), y: Int32(newY))
            }

        guard !updates.isEmpty else { return }

        let ok = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
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

        // The CGCompleteDisplayConfiguration above triggers the reconfig
        // callback, which in turn calls DisplayManager.refreshDisplays — no
        // explicit refresh needed here.
        _ = ok
    }

    // MARK: - Private

    private func teardown() {
        for (_, win) in overlayWindows { win.close() }
        overlayWindows.removeAll()
        calibratingDisplays = []
        lineFraction.removeAll()
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
        // Workaround for the rotated-display NSWindow positioning bug — see
        // IdentifyDisplayService for details.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: frame.width, height: frame.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.setFrame(frame, display: false)
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        window.level = .floating + 1
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        let view = CalibrationOverlayView(
            display: display,
            isMain: display.displayID == mainDisplayID
        )
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
    let isMain: Bool
    @ObservedObject private var svc = CrossingCalibrationService.shared

    /// Tracks the line position locally so dragging is responsive; flushed to
    /// the shared service on every update.
    @State private var localFraction: CGFloat = 0.5
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Click-through transparent backdrop captured by the NSWindow;
                // this layer is just for layout.
                Color.clear

                // The line + drag handle on the right side
                ZStack {
                    Rectangle()
                        .fill(DisplayAccent.color(for: display.displayUUID).opacity(isDragging ? 1.0 : 0.85))
                        .frame(height: 2)

                    HStack {
                        Spacer()
                        Circle()
                            .fill(DisplayAccent.color(for: display.displayUUID))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: "arrow.up.and.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                            .padding(.trailing, 40)
                    }
                }
                .frame(width: geo.size.width)
                .position(x: geo.size.width / 2, y: localFraction * geo.size.height)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let f = max(0.05, min(0.95, value.location.y / geo.size.height))
                            localFraction = f
                            svc.lineFraction[display.displayID] = f
                        }
                        .onEnded { _ in isDragging = false }
                )

                // Instruction header at top
                VStack(spacing: 4) {
                    Text(display.name)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundColor(.white)
                    Text("Drag the line to where the cursor should cross")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                .padding(.top, 60)
                .frame(maxWidth: .infinity)

                // Apply / Cancel panel only on the main display
                if isMain {
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            CrossingCalibrationService.shared.cancel()
                        }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)

                        Button("Apply") {
                            Task { await CrossingCalibrationService.shared.apply() }
                        }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 60)
                }
            }
        }
        .onAppear {
            localFraction = svc.lineFraction[display.displayID] ?? 0.5
        }
    }
}
