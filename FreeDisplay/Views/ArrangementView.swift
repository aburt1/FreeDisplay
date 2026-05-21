import SwiftUI

/// Visual display arrangement view.
/// Shows all active displays as scaled thumbnails on a canvas.
/// Supports drag-to-reposition and "Set as main display" button for secondary displays.
struct ArrangementView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var draggedID: CGDirectDisplayID?
    @State private var dragOffset: CGSize = .zero
    /// Translation after edge-snap is applied — what's actually committed on drag-end.
    @State private var snappedOffset: CGSize = .zero
    /// Active alignment guide lines in canvas space. Drawn while the dragged
    /// thumbnail's edge is snapped to another display's edge.
    @State private var snapGuides: [SnapGuide] = []
    @State private var dragError: String?

    private let canvasHeight: CGFloat = 160
    /// Canvas-pixel threshold within which an edge magnetically snaps.
    private let snapThreshold: CGFloat = 8

    /// True when the main display and any non-main display have non-matching
    /// vertical centers (which is what causes cursor-jump between displays).
    /// Used to dim the Align button when there's nothing to fix.
    private var centersMisaligned: Bool {
        guard let main = displayManager.displays.first(where: { $0.isMain }) else { return false }
        let mainMidY = main.bounds.midY
        return displayManager.displays.contains { d in
            !d.isMain && abs(d.bounds.midY - mainMidY) > 0.5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Quick-align row. Each button lives on its own line of intent —
            // we deliberately keep this very small so it doesn't dominate.
            HStack(spacing: 6) {
                Button {
                    Task { @MainActor in
                        let ok = await ArrangementService.shared.alignVerticalCenters(
                            among: displayManager.displays
                        )
                        if ok { displayManager.refreshDisplays() }
                    }
                } label: {
                    Label("Align Centers", systemImage: "align.vertical.center")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(centersMisaligned ? 0.15 : 0.06))
                        .foregroundColor(centersMisaligned ? .accentColor : .secondary)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(displayManager.displays.count < 2)
                .help("Aligns every other display's vertical center with the main display so the cursor crosses smoothly between them at any height.")

                Button {
                    CrossingCalibrationService.shared.begin(displays: displayManager.displays)
                } label: {
                    Label("Calibrate Crossing", systemImage: "arrow.left.and.right")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .disabled(displayManager.displays.count < 2)
                .help("Interactive calibration: drag a line on each display to mark the natural crossing point, then we'll align the displays so the cursor flows smoothly between those points.")

                Spacer()
            }

            // Visual canvas
            GeometryReader { geo in
                ZStack {
                    // Grid background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.underPageBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    // Alignment guides (rendered behind thumbnails so the dragged
                    // thumbnail stays visible on top of the line).
                    ForEach(snapGuides) { guide in
                        guide.path
                            .stroke(Color.accentColor.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                    }

                    // Display thumbnails
                    thumbnails(canvasSize: geo.size)
                }
            }
            .frame(height: canvasHeight)

            // Drag error feedback
            if let err = dragError {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }

            // "Set as main display" for non-main displays
            ForEach(displayManager.displays.filter { !$0.isMain }) { display in
                Button(action: {
                    Task { @MainActor in
                        let ok = await ArrangementService.shared.setAsMainDisplay(
                            display.displayID,
                            among: displayManager.displays
                        )
                        if ok { displayManager.refreshDisplays() }
                    }
                }) {
                    Label("Set \(display.name) as Main Display", systemImage: "star.fill")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Make this display the main display")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func thumbnails(canvasSize: CGSize) -> some View {
        let layout = computeLayout(canvasSize: canvasSize)
        ForEach(displayManager.displays) { display in
            let rect = layout[display.displayID] ?? CGRect(x: canvasSize.width / 2, y: canvasSize.height / 2, width: 60, height: 40)
            let isDragged = draggedID == display.displayID
            // Use the snapped offset for the dragged thumbnail's position so the
            // thumbnail visibly clicks into alignment, not just the drop result.
            let activeOffset = isDragged ? snappedOffset : .zero
            DisplayThumbnailView(display: display, isDragged: isDragged)
                .frame(width: max(rect.width, 40), height: max(rect.height, 25))
                .position(
                    x: rect.midX + activeOffset.width,
                    y: rect.midY + activeOffset.height
                )
                .help("Display: \(display.name)")
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            draggedID = display.displayID
                            dragOffset = value.translation
                            let result = snapResult(
                                draggedID: display.displayID,
                                rawTranslation: value.translation,
                                layout: layout
                            )
                            snappedOffset = result.translation
                            snapGuides = result.guides
                        }
                        .onEnded { value in
                            let result = snapResult(
                                draggedID: display.displayID,
                                rawTranslation: value.translation,
                                layout: layout
                            )
                            applyDrag(
                                for: display,
                                translation: result.translation,
                                layout: layout,
                                canvasSize: canvasSize
                            )
                            draggedID = nil
                            dragOffset = .zero
                            snappedOffset = .zero
                            snapGuides = []
                        }
                )
        }
    }

    // MARK: - Snap logic

    /// Computes the snapped translation and the guide lines to render, given the
    /// raw drag translation. Snaps when the dragged thumbnail's top/center/bottom
    /// edges are within `snapThreshold` of any other display's top/center/bottom
    /// (Y-axis snap), and similarly for left/center/right (X-axis snap).
    /// Selects the closest candidate per axis independently.
    private func snapResult(
        draggedID id: CGDirectDisplayID,
        rawTranslation: CGSize,
        layout: [CGDirectDisplayID: CGRect]
    ) -> (translation: CGSize, guides: [SnapGuide]) {
        guard let origRect = layout[id] else {
            return (rawTranslation, [])
        }
        let dragged = origRect.offsetBy(dx: rawTranslation.width, dy: rawTranslation.height)

        let others = layout
            .filter { $0.key != id }
            .map { $0.value }
        guard !others.isEmpty else {
            return (rawTranslation, [])
        }

        // For each axis, candidate "anchor lines" on the dragged rect.
        let xCandidates: [(name: String, value: CGFloat)] = [
            ("min", dragged.minX), ("mid", dragged.midX), ("max", dragged.maxX),
        ]
        let yCandidates: [(name: String, value: CGFloat)] = [
            ("min", dragged.minY), ("mid", dragged.midY), ("max", dragged.maxY),
        ]

        // Best X snap: smallest distance between any dragged-X-anchor and any
        // other-display-X-anchor (including each other's edges + centers).
        var bestX: (delta: CGFloat, line: CGFloat)? = nil
        var bestY: (delta: CGFloat, line: CGFloat)? = nil

        for other in others {
            let otherXs: [CGFloat] = [other.minX, other.midX, other.maxX]
            let otherYs: [CGFloat] = [other.minY, other.midY, other.maxY]

            for cand in xCandidates {
                for ox in otherXs {
                    let d = ox - cand.value
                    if abs(d) <= snapThreshold,
                       bestX == nil || abs(d) < abs(bestX!.delta) {
                        bestX = (delta: d, line: ox)
                    }
                }
            }
            for cand in yCandidates {
                for oy in otherYs {
                    let d = oy - cand.value
                    if abs(d) <= snapThreshold,
                       bestY == nil || abs(d) < abs(bestY!.delta) {
                        bestY = (delta: d, line: oy)
                    }
                }
            }
        }

        let adjustedTranslation = CGSize(
            width: rawTranslation.width + (bestX?.delta ?? 0),
            height: rawTranslation.height + (bestY?.delta ?? 0)
        )

        // Build guide-line paths: vertical line at bestX, horizontal at bestY.
        // Each extends a bit past the union of dragged + the closest other,
        // so the line visually connects what's aligning.
        let finalRect = origRect.offsetBy(dx: adjustedTranslation.width, dy: adjustedTranslation.height)
        var guides: [SnapGuide] = []
        if let bx = bestX {
            // Find the y-range to draw across (union of finalRect Y and the other displays')
            let yMin = others.map(\.minY).min().map { min($0, finalRect.minY) } ?? finalRect.minY
            let yMax = others.map(\.maxY).max().map { max($0, finalRect.maxY) } ?? finalRect.maxY
            guides.append(SnapGuide(
                id: "x",
                path: Path { p in
                    p.move(to: CGPoint(x: bx.line, y: yMin - 6))
                    p.addLine(to: CGPoint(x: bx.line, y: yMax + 6))
                }
            ))
        }
        if let by = bestY {
            let xMin = others.map(\.minX).min().map { min($0, finalRect.minX) } ?? finalRect.minX
            let xMax = others.map(\.maxX).max().map { max($0, finalRect.maxX) } ?? finalRect.maxX
            guides.append(SnapGuide(
                id: "y",
                path: Path { p in
                    p.move(to: CGPoint(x: xMin - 6, y: by.line))
                    p.addLine(to: CGPoint(x: xMax + 6, y: by.line))
                }
            ))
        }

        return (adjustedTranslation, guides)
    }

    /// Computes the canvas-space rect for each display, scaled to fit the canvas.
    private func computeLayout(canvasSize: CGSize) -> [CGDirectDisplayID: CGRect] {
        let displays = displayManager.displays
        guard !displays.isEmpty else { return [:] }

        let allBounds = displays.map { CGDisplayBounds($0.displayID) }
        let minX = allBounds.map { $0.minX }.min() ?? 0
        let minY = allBounds.map { $0.minY }.min() ?? 0
        let maxX = allBounds.map { $0.maxX }.max() ?? 1
        let maxY = allBounds.map { $0.maxY }.max() ?? 1

        let totalW = maxX - minX
        let totalH = maxY - minY
        guard totalW > 0, totalH > 0 else { return [:] }

        let padding: CGFloat = 16
        let availW = canvasSize.width - padding * 2
        let availH = canvasSize.height - padding * 2

        let scale = min(availW / totalW, availH / totalH)
        let scaledW = totalW * scale
        let scaledH = totalH * scale
        let offsetX = padding + (availW - scaledW) / 2
        let offsetY = padding + (availH - scaledH) / 2

        var result: [CGDirectDisplayID: CGRect] = [:]
        for display in displays {
            let bounds = CGDisplayBounds(display.displayID)
            let x = offsetX + (bounds.minX - minX) * scale
            let y = offsetY + (bounds.minY - minY) * scale
            let w = bounds.width * scale
            let h = bounds.height * scale
            result[display.displayID] = CGRect(x: x, y: y, width: w, height: h)
        }
        return result
    }

    /// Converts the drag translation to screen coordinates and applies the new position.
    private func applyDrag(for display: DisplayInfo, translation: CGSize, layout: [CGDirectDisplayID: CGRect], canvasSize: CGSize) {
        let displays = displayManager.displays
        guard !displays.isEmpty else { return }

        let allBounds = displays.map { CGDisplayBounds($0.displayID) }
        let minX = allBounds.map { $0.minX }.min() ?? 0
        let minY = allBounds.map { $0.minY }.min() ?? 0
        let maxX = allBounds.map { $0.maxX }.max() ?? 1
        let maxY = allBounds.map { $0.maxY }.max() ?? 1

        let totalW = maxX - minX
        let totalH = maxY - minY
        guard totalW > 0, totalH > 0 else { return }

        let padding: CGFloat = 16
        let availW = canvasSize.width - padding * 2
        let availH = canvasSize.height - padding * 2
        let scale = min(availW / totalW, availH / totalH)
        guard scale > 0 else { return }

        let deltaX = Int(translation.width / scale)
        let deltaY = Int(translation.height / scale)
        let newX = Int(display.bounds.origin.x) + deltaX
        let newY = Int(display.bounds.origin.y) + deltaY

        Task { @MainActor in
            let ok = await ArrangementService.shared.setPosition(x: newX, y: newY, for: display.displayID)
            if ok {
                displayManager.refreshDisplays()
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    dragError = "Failed to rearrange display, please try again"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { self.dragError = nil }
                }
            }
        }
    }
}

// MARK: - Display Thumbnail

private struct DisplayThumbnailView: View {
    let display: DisplayInfo
    let isDragged: Bool

    var body: some View {
        ZStack {
            // Background fill
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    display.isBuiltin
                    ? AnyShapeStyle(LinearGradient(
                        colors: [.blue.opacity(0.75), .purple.opacity(0.65)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            isDragged ? Color.accentColor : (display.isMain ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.4)),
                            lineWidth: isDragged ? 2 : (display.isMain ? 1.5 : 1)
                        )
                )

            // Decorative top bar for external displays (bezel-like)
            if !display.isBuiltin {
                VStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 3)
                    Spacer()
                }
                .padding(.horizontal, 3)
                .padding(.top, 3)
            }

            // Display name + main-display marker
            VStack(spacing: 2) {
                Text(display.name)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(display.isBuiltin ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if display.isMain {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 5))
                        Text("Main")
                            .font(.system(size: 6))
                    }
                    .foregroundColor(display.isBuiltin ? .white.opacity(0.9) : .blue)
                }
            }
            .padding(3)
        }
        .scaleEffect(isDragged ? 1.04 : 1.0)
        .shadow(color: .black.opacity(isDragged ? 0.3 : 0.05), radius: isDragged ? 6 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDragged)
    }
}

// MARK: - SnapGuide

/// A single alignment guide line (horizontal or vertical) rendered while
/// the user is dragging a display thumbnail near another display's edge.
private struct SnapGuide: Identifiable {
    let id: String
    let path: Path
}
