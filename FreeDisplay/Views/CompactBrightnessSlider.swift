import SwiftUI

/// Tight horizontal brightness slider designed for the menu's display row.
/// Strips the full `BrightnessSliderView`'s mode indicator and percentage
/// pill — those still live behind the row's expanded detail view if the
/// user wants to inspect DDC vs Software mode.
///
/// Uses the per-display accent color for the slider tint so a user can
/// glance at the menu and tell which slider belongs to which physical screen.
struct CompactBrightnessSlider: View {
    @ObservedObject var display: DisplayInfo
    let accent: Color

    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var lastDDCWrite: Date = .distantPast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: sunIconName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)

            Slider(value: $localBrightness, in: 5...100, step: 1) { editing in
                isDragging = editing
                if !editing {
                    // Drag ended — smooth-apply the final value.
                    let final = localBrightness
                    Task { @MainActor in
                        BrightnessService.shared.setBrightnessSmooth(final, for: display)
                    }
                    lastDDCWrite = Date()
                }
            }
            .tint(accent)
            .controlSize(.small)
            .accessibilityLabel("\(display.name) brightness")
            .accessibilityValue("\(Int(localBrightness))%")
            .onChange(of: localBrightness) { _, newValue in
                guard isDragging else { return }
                // Throttle DDC writes to ~100ms while dragging; service is no-op
                // for built-in (uses gamma synchronously).
                let now = Date()
                if !display.isBuiltin, now.timeIntervalSince(lastDDCWrite) < 0.1 {
                    display.brightness = newValue
                    return
                }
                lastDDCWrite = now
                display.brightness = newValue
                Task { @MainActor in
                    await BrightnessService.shared.setBrightness(newValue, for: display)
                }
            }
            .disabled(display.isDisconnected)

            Text("\(Int(localBrightness))%")
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .opacity(display.isDisconnected ? 0.35 : 1.0)
        .onAppear { localBrightness = display.brightness }
        .onChange(of: display.brightness) { _, newValue in
            // Sync from external changes (auto-brightness, presets) unless the
            // user is currently dragging — local state wins during interaction.
            if !isDragging {
                localBrightness = newValue
            }
        }
    }

    private var sunIconName: String {
        if localBrightness < 30 { return "sun.min" }
        if localBrightness < 70 { return "sun.min.fill" }
        return "sun.max.fill"
    }
}
