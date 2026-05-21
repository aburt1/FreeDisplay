import SwiftUI

// MARK: - Shared Icon Helper

/// A colored rounded-square SF Symbol icon, consistent with macOS Settings style.
struct MenuItemIcon: View {
    let systemName: String
    var color: Color = .blue

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

// MARK: - ExpandableRow

struct ExpandableRow: View {
    let icon: String
    var iconColor: Color = .blue
    let label: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: icon, color: iconColor)
            Text(label).font(.body)
            Spacer()
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isExpanded ? "\(label), expanded" : "\(label), collapsed")
        .accessibilityHint("Click to expand or collapse this section")
        .accessibilityAddTraits(.isButton)
        .help("Click to expand or collapse this section")
    }
}

struct MenuBarView: View {
    @EnvironmentObject var displayManager: DisplayManager
    @ObservedObject private var updateService = UpdateService.shared
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var virtualDisplayService = VirtualDisplayService.shared
    @State private var expandedDisplayIDs: Set<CGDirectDisplayID> = []
    @State private var showArrangement: Bool = false
    @State private var showMore: Bool = false
    @State private var showVirtualDisplays: Bool = false
    @State private var showAutoBrightness: Bool = false
    @State private var quitHovered = false
    @State private var settingsHovered = false
    @State private var settingsWindow: NSWindow?

    private var visibleDisplays: [DisplayInfo] {
        displayManager.displays.filter { !virtualDisplayService.isVirtualDisplay($0.displayID) }
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Display list
                ForEach(visibleDisplays) { display in
                    VStack(spacing: 0) {
                        DisplayRowView(
                            display: display,
                            isExpanded: expandedDisplayIDs.contains(display.displayID),
                            onToggleExpand: {
                                if expandedDisplayIDs.contains(display.displayID) {
                                    expandedDisplayIDs.remove(display.displayID)
                                } else {
                                    expandedDisplayIDs.insert(display.displayID)
                                }
                            }
                        )

                        if expandedDisplayIDs.contains(display.displayID) {
                            DisplayDetailView(display: display)
                        }
                    }
                }

                // Compact preset pill row — replaces the chunky full-width
                // segmented control. The `+` to save lives inline with the chips.
                Divider().opacity(0.3).padding(.vertical, 2)
                PresetPillRow()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                // Arrange Displays — primary multi-display surface
                // (calibration + alignment all live in here).
                if visibleDisplays.count > 1 {
                    Divider().opacity(0.3).padding(.vertical, 2)
                    ExpandableRow(
                        icon: "rectangle.3.offgrid",
                        iconColor: .blue,
                        label: "Arrange Displays",
                        isExpanded: $showArrangement
                    )
                    if showArrangement {
                        ArrangementView()
                            .environmentObject(displayManager)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                // "More" — the power-user features (Virtual Display, Auto Brightness)
                // collapsed by default so they don't compete with primary actions.
                Divider().opacity(0.3).padding(.vertical, 2)
                ExpandableRow(
                    icon: "ellipsis.circle",
                    iconColor: .gray,
                    label: "More",
                    isExpanded: $showMore
                )
                if showMore {
                    VStack(alignment: .leading, spacing: 0) {
                        ExpandableRow(
                            icon: "display.2",
                            iconColor: .blue,
                            label: "Virtual Display",
                            isExpanded: $showVirtualDisplays
                        )
                        if showVirtualDisplays {
                            VirtualDisplayView()
                                .padding(.leading, 8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        ExpandableRow(
                            icon: "sun.and.horizon.fill",
                            iconColor: .orange,
                            label: "Auto Brightness",
                            isExpanded: $showAutoBrightness
                        )
                        if showAutoBrightness {
                            AutoBrightnessView()
                                .padding(.leading, 8)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Divider().opacity(0.3).padding(.vertical, 2)

                // Update notice (Phase 12)
                if updateService.hasUpdate, let ver = updateService.latestVersion {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("New version v\(ver) available")
                            .font(.caption)
                            .foregroundColor(.green)
                        Spacer()
                        Button("View") { updateService.openReleasePage() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .help("Download and install the latest version")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(6)
                    .padding(.horizontal, 8)
                }

            }
            .fixedSize(horizontal: false, vertical: true)
        }
        // Let the popover size to the actual content but cap at 700pt so a
        // user with many displays + everything expanded still scrolls instead
        // of overflowing the screen. The fixedSize(vertical: true) above gives
        // the ScrollView a concrete content height to compose against.
        .frame(maxHeight: 700)

        Divider().opacity(0.3)

        // Version and quit button (pinned at the bottom, does not scroll)
        HStack {
            Text("FreeDisplay v\(updateService.currentVersion)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            Spacer()
            // Settings gear — opens a real Settings window (⌘, also works).
            Button(action: { openSettingsWindow() }) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(settingsHovered ? Color.primary.opacity(0.06) : .clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(settingsHovered ? .primary : .secondary)
            .onHover { settingsHovered = $0 }
            .help("Settings")

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark")
                        .accessibilityHidden(true)
                    Text("Quit")
                }
                .font(.body)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(quitHovered ? Color.primary.opacity(0.06) : .clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(quitHovered ? .red : .secondary)
            .onHover { quitHovered = $0 }
            .help("Quit FreeDisplay")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        } // end VStack
        .frame(width: 440)
        .frame(maxHeight: 800)
        .padding(.vertical, 8)
        .onReceive(displayManager.$displays) { newDisplays in
            let validIDs = Set(newDisplays.map { $0.displayID })
            expandedDisplayIDs = expandedDisplayIDs.intersection(validIDs)
        }
        .task {
            if settings.checkUpdatesOnLaunch {
                await updateService.checkForUpdates()
            }
        }
    }

    /// Opens (or focuses) a dedicated Settings window. We don't use the
    /// `Settings { … }` Scene because LSUIElement apps don't get a proper app
    /// menu wired up — instead we manage an `NSWindow` ourselves and bring it
    /// to front. The window itself hosts the existing `SettingsView` SwiftUI.
    @MainActor
    private func openSettingsWindow() {
        // If we already have a window open, just focus it.
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "FreeDisplay Settings"
        win.center()
        win.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView()
            .frame(width: 340)
            .padding(.vertical, 12))
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }
}

// MARK: - PresetPillRow — compact presets strip

/// Horizontal row of preset chips with an inline "+" save button. Replaces the
/// previous chunky segmented control + separate "Save as Preset" row. Built-ins
/// and user presets render identically; the active preset highlights in accent.
struct PresetPillRow: View {
    @ObservedObject private var presetService = PresetService.shared
    @State private var showSaveSheet = false

    var body: some View {
        let presets = presetService.presets
        let currentID = presetService.currentPresetMatch()

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    PresetPill(
                        preset: preset,
                        isActive: currentID == preset.id,
                        isApplying: presetService.applyingPresetID == preset.id,
                        isDisabled: presetService.isApplying
                    )
                }

                // Inline "+" to save the current state as a new preset.
                Button(action: { showSaveSheet = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Save current display configuration as a preset")
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            SavePresetView()
        }
    }
}

/// A single pill button representing one preset.
private struct PresetPill: View {
    let preset: DisplayPreset
    let isActive: Bool
    let isApplying: Bool
    let isDisabled: Bool

    @State private var isHovered = false

    var body: some View {
        Button(action: apply) {
            HStack(spacing: 4) {
                if isApplying {
                    ProgressView().scaleEffect(0.4).frame(width: 10, height: 10)
                } else {
                    Image(systemName: preset.icon)
                        .font(.caption2)
                        .foregroundColor(isActive ? .white : .secondary)
                }
                Text(preset.name)
                    .font(.caption)
                    .fontWeight(isActive ? .medium : .regular)
                    .foregroundColor(isActive ? .white : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(
                    isActive ? Color.accentColor
                    : isHovered ? Color.primary.opacity(0.08)
                    : Color.primary.opacity(0.04)
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .help(isActive ? "Currently active" : "Apply preset: \(preset.name)")
    }

    private func apply() {
        guard !isDisabled else { return }
        Task { await PresetService.shared.applyPreset(preset) }
    }
}

// MARK: - SettingsView (Phase 12: embedded in MenuBarView)

struct SettingsView: View {
    @ObservedObject private var settings = SettingsService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Launch at login
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    if newValue {
                        LaunchService.shared.enable()
                    } else {
                        LaunchService.shared.disable()
                    }
                    settings.launchAtLogin = newValue
                }
            )) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "power", color: .green)
                        .accessibilityHidden(true)
                    Text("Launch at Login")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Automatically start FreeDisplay at login")

            // First-launch hint: recommend enabling Launch at Login
            if !settings.launchAtLoginPrompted {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Recommended: enable Launch at Login")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Got it") {
                        settings.launchAtLoginPrompted = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .onAppear {
                    // Mark as prompted so it only shows once
                    // User dismisses manually via the "Got it" button
                }
            }

            // Show combined brightness control
            Toggle(isOn: $settings.showCombinedBrightness) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "sun.min.fill", color: .yellow)
                        .accessibilityHidden(true)
                    Text("Show combined brightness control")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Show a unified brightness slider for all displays in the menu bar")

            // Check for updates on launch
            Toggle(isOn: $settings.checkUpdatesOnLaunch) {
                HStack(spacing: 6) {
                    MenuItemIcon(systemName: "arrow.clockwise.circle", color: .blue)
                        .accessibilityHidden(true)
                    Text("Check for updates on launch")
                        .font(.body)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .help("Automatically check for new versions on each launch")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - DisplayRowView

struct DisplayRowView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var isHovered: Bool = false

    let isExpanded: Bool
    let onToggleExpand: () -> Void

    private var accent: Color {
        display.isDisconnected ? .gray : DisplayAccent.color(for: display.displayUUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: identity + name + main badge + disconnect toggle.
            // Tapping anywhere in this strip (except the toggle) expands the row.
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                    .rotationEffect(Angle(degrees: isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    .accessibilityHidden(true)

                // Accent identity dot — same color used by the slider tint and
                // the identify-display flash overlay, so the link is obvious.
                Circle()
                    .fill(accent)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .accessibilityHidden(true)

                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Text(display.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(display.isDisconnected ? .secondary : .primary)

                if display.isMain {
                    Text("Main")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.15))
                        .cornerRadius(3)
                }

                Spacer(minLength: 4)

                // Disconnect toggle — its own gesture, won't trigger row expand.
                Toggle("", isOn: Binding(
                    get: { !display.isDisconnected },
                    set: { newValue in
                        guard !display.isTogglingConnection else { return }
                        Task { await DisplayConnectionService.shared.setConnected(newValue, for: display) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(display.isTogglingConnection || !DisplayConnectionService.shared.symbolsLoaded)
                .help(display.isDisconnected ? "Reconnect display" : "Disconnect display (macOS will treat it as offline)")
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }

            // Inline brightness slider — the modal task, zero clicks to access.
            // Hidden for disconnected displays since DDC/gamma won't reach them.
            if !display.isDisconnected {
                CompactBrightnessSlider(display: display, accent: accent)
                    .padding(.leading, 27)   // align under name (past chevron + dot + icon)
            }

            // Footnote: resolution / status.
            HStack(spacing: 4) {
                if display.isDisconnected {
                    Text("Disconnected")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if let mode = display.currentDisplayMode {
                    Text(mode.resolutionString)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if mode.isHiDPI {
                        Text("·").font(.caption2).foregroundColor(.secondary)
                        Text("HiDPI").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.leading, 27)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHovered ? 0.05 : 0))
                .padding(.horizontal, 4)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            // Identify-display flash on sustained hover; debounced in the service.
            if hovering && !display.isDisconnected {
                IdentifyDisplayService.shared.scheduleFlash(for: display)
            } else {
                IdentifyDisplayService.shared.cancelScheduled(for: display.displayID)
            }
        }
        .contextMenu {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("Open in System Settings", systemImage: "display")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display.name, forType: .string)
            } label: {
                Label("Copy display name", systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("Display: \(display.name)\(display.isMain ? ", main display" : "")\(isExpanded ? ", expanded" : ", collapsed")")
        .accessibilityHint("Click to expand control panel")
        .accessibilityAddTraits(.isButton)
    }
}

