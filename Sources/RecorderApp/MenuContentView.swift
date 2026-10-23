import AppKit
import CameraCapture
import RecorderCore
import SwiftUI
import WindowTools

/// The menu-bar window: mode, camera and screen setup, preflight, Start/Stop and the rest.
/// `MenuBarController` hosts it in its panel and sizes the panel to the content height this view
/// reports. Content taller than the screen scrolls, so Quit and the Permissions buttons stay
/// reachable on the 14" display.
struct MenuContentView: View {
    @Bindable var coordinator: SessionCoordinator
    let menu: MenuPanelModel
    @State private var showPermissions = false
    @State private var showOptions = false
    @State private var showControlBarSettings = false
    @State private var showKeystrokeSettings = false
    @State private var showShortcuts = false

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menu.contentHeightChanged($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Fills the panel; the panel's height is the content height, up to the screen's limit.
        .frame(width: MenuPanelPlacement.width)
        // The panel keeps this view between opens, so each open refreshes here.
        .onChange(of: menu.openCount, initial: true) { menuOpened() }
    }

    private func menuOpened() {
        coordinator.permissions.refresh()
        if PermissionKind.allCases.contains(where: { $0.isRequired && coordinator.permissions.state($0) != .granted }) {
            showPermissions = true
        }
    }

    private var content: some View {
        @Bindable var settings = coordinator.settings
        return VStack(alignment: .leading, spacing: 12) {
            header
            // The camera mic warning and the camera's own trouble, above everything else.
            AlertBannerList(coordinator: coordinator)
            Picker("Mode", selection: $settings.mode) {
                ForEach(RecordingMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!coordinator.state.canStart)

            if settings.mode.includesCamera { CameraSection(coordinator: coordinator) }
            if settings.mode.includesScreen { ScreenSection(coordinator: coordinator) }

            IssuesList(coordinator: coordinator)
            RecordControls(coordinator: coordinator) { menu.close() }
            // While recording, and before recording while the camera preview is on (decision 1:
            // camera mic and Mac mic; computer sound only while recording).
            if coordinator.menuShowsMeters {
                LevelMetersPanel(coordinator: coordinator)
            }
            StatusArea(coordinator: coordinator)

            Divider()
            DisclosureGroup(isExpanded: $showPermissions) {
                PermissionsPanel(permissions: coordinator.permissions).padding(.top, 4)
            } label: {
                Text("Permissions").font(.headline)
            }
            DisclosureGroup(isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    OptionsPanel(settings: settings, idle: coordinator.state.canStart)
                    // An audio-only check of the camera mic and the Mac mic, while nothing records.
                    // Rarely needed: the meters run whenever the camera preview is on.
                    if settings.mode.includesCamera, coordinator.state.canStart {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mic check").font(.callout.weight(.semibold))
                            MicCheckControls(coordinator: coordinator)
                        }
                    }
                    Divider()
                    MicCalibrationPanel(coordinator: coordinator)
                }
                .padding(.top, 4)
            } label: {
                Text("Recording Settings").font(.headline)
            }
            // A mic check started from the camera window shows its countdown and meters here.
            .onChange(of: coordinator.micCheck != nil) { _, running in if running { showOptions = true } }
            ControlBarSettingsRow(coordinator: coordinator, isExpanded: $showControlBarSettings)
            KeystrokeSettingsRow(coordinator: coordinator, isExpanded: $showKeystrokeSettings)
            DisclosureGroup(isExpanded: $showShortcuts) {
                ShortcutsPanel(errors: coordinator.hotKeyErrors).padding(.top, 4)
            } label: {
                Text("Shortcuts").font(.headline)
            }

            Divider()
            HStack {
                Button("Open Recordings Folder") { openRecordingsFolder() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: MenuPanelPlacement.width)
        .onChange(of: settings.fingerprint) { coordinator.settingsChanged() }
        .onChange(of: settings.dimOutsideFrame) { coordinator.settingsChanged() }
        .onChange(of: settings.showCameraPreview) { coordinator.settingsChanged() }
        .onChange(of: settings.keystrokeMode) { coordinator.updateKeystrokes() }
        .onChange(of: settings.keystrokesInScreen) { coordinator.updateKeystrokes() }
    }

    private var header: some View {
        HStack {
            Text("TwinTake").font(.headline)
            Spacer()
            Text(stateText).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var stateText: String {
        switch coordinator.state {
        case .idle: coordinator.hasBlockers ? "Not ready" : "Ready"
        case .preparing: "Starting…"
        case .recording: "Recording \(coordinator.elapsedText)"
        case .stopping: "Saving…"
        case .error: "Error"
        }
    }

    private func openRecordingsFolder() {
        let folder = coordinator.settings.outputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

// MARK: - Sections

/// A titled group with a light background.
private struct SectionBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

private struct CameraSection: View {
    @Bindable var coordinator: SessionCoordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        let idle = coordinator.state.canStart
        SectionBox(title: "Camera", systemImage: "video") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    RowLabel("Device")
                    Picker("Device", selection: $settings.camera) {
                        Text("Automatic (\(name(coordinator.automatic.camera, in: coordinator.videoDevices)))").tag(DeviceChoice.automatic)
                        deviceItems(coordinator.videoDevices, selected: settings.camera)
                    }
                    .labelsHidden()
                }
                GridRow {
                    RowLabel("Audio")
                    Picker("Audio", selection: $settings.cameraAudio) {
                        Text("Automatic (\(name(coordinator.automatic.cameraAudio, in: coordinator.audioDevices)))").tag(DeviceChoice.automatic)
                        deviceItems(coordinator.audioDevices, selected: settings.cameraAudio)
                        Divider()
                        Text("No audio").tag(DeviceChoice.none)
                    }
                    .labelsHidden()
                }
                GridRow(alignment: .firstTextBaseline) {
                    RowLabel("Signal")
                    SignalLineView(line: coordinator.cameraSignalLine)
                }
            }
            .disabled(!idle)

            CameraWindowControls(coordinator: coordinator)

            // The preview's own header row, right above the picture.
            HStack {
                Text("Live preview").font(.callout)
                Spacer()
                Toggle("Live preview", isOn: $settings.showCameraPreview)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("Shows the camera here while the menu is open, with the camera mic and Mac mic meters under Start. "
                          + "The camera and its mics close 1.5 s after nothing shows the camera.")
            }
            .disabled(!idle)
            if settings.showCameraPreview, idle {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.black)
                    // Holds only the frame feed, so SwiftUI can add or remove it at any time.
                    CameraPreviewView(feed: coordinator.previewFeed)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .opacity(coordinator.preview == .live ? 1 : 0)
                    if let message = coordinator.preview.message {
                        Text(message)
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).padding(8)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
    }
}

/// The read-only Signal line: what camera.mov records. A capture card short of 4K shows in
/// warning style with one short fix under it.
private struct SignalLineView: View {
    let line: CameraSignalLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if line.isWarning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(line.text)
                    .foregroundStyle(line.isWarning ? Color.orange : Color.primary)
                    .monospacedDigit()
            }
            if let fix = line.fix {
                Text(fix).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help("camera.mov records what the camera sends. Change it on the camera.")
    }
}

/// A disclosure arrow that shows or hides a row's options.
private struct DisclosureArrow: View {
    @Binding var isExpanded: Bool
    var label: String

    var body: some View {
        Button { isExpanded.toggle() } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide \(label)" : "Show \(label)")
        .help(isExpanded ? "Hide \(label)" : "Show \(label)")
    }
}

/// The Camera window switch, with its options under a disclosure arrow. The switch also works
/// while recording.
private struct CameraWindowControls: View {
    @Bindable var coordinator: SessionCoordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        let idle = coordinator.state.canStart
        HStack(spacing: 4) {
            DisclosureArrow(isExpanded: $settings.cameraWindowOptionsShown, label: "camera window options")
            Toggle("Camera window", isOn: Binding(get: { coordinator.settings.cameraWindowShown },
                                                  set: { coordinator.setCameraWindowShown($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("A floating picture of the camera, never recorded. Right-click it for Mirror and sizes.")
            Spacer()
            Text(HotKey.cameraWindow.displayString).font(.caption).foregroundStyle(.secondary)
        }
        if settings.cameraWindowOptionsShown {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Mirror", isOn: $settings.cameraWindowMirrored)
                    .help("Mirrors the window's picture, like a webcam. camera.mov is never mirrored.")
                Toggle("Keep the camera window on while recording", isOn: $settings.cameraWindowWhileRecording)
                Toggle("Live picture while recording", isOn: $settings.previewWhileRecording)
                    .disabled(!idle || !settings.cameraWindowWhileRecording)
                    .help("Keeps a small 640×360 preview output in the camera session while camera.mov records. "
                          + "Off: Start removes it, and the window shows only the timer. Applies at the next Start.")
            }
            .toggleStyle(.checkbox)
            .padding(.leading, 18)
            .onChange(of: settings.cameraWindowWhileRecording) { coordinator.cameraWindowSettingsChanged() }
        }
    }
}

private struct ScreenSection: View {
    @Bindable var coordinator: SessionCoordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        let idle = coordinator.state.canStart
        let resolved = coordinator.resolvedDisplay()?.display
        SectionBox(title: "Screen", systemImage: "rectangle.dashed") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    RowLabel("Display")
                    Picker("Display", selection: $settings.displayUUID) {
                        Text("Automatic (\(coordinator.automaticDisplay?.name ?? "none"))").tag(String?.none)
                        ForEach(coordinator.displays) { d in
                            Text(d.name + (d.isBuiltin ? " (built-in)" : "")).tag(String?.some(d.uuid))
                        }
                        if let uuid = settings.displayUUID, !coordinator.displays.contains(where: { $0.uuid == uuid }) {
                            Text("Saved display (not connected)").tag(String?.some(uuid))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    RowLabel("Frame")
                    HStack(spacing: 8) {
                        Picker("Frame", selection: $settings.framePresetID) {
                            Text("Automatic (\(resolved?.defaultPreset.autoName ?? "none"))").tag(String?.none)
                            ForEach(ScreenFramePreset.all) { Text($0.shortName).tag(String?.some($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if let resolved {
                            let px = resolved.outputPixels(for: coordinator.resolvedPreset(for: resolved))
                            Text("\(px.width.formatted())×\(px.height.formatted()) px\non \(resolved.name)")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GridRow {
                    RowLabel("Mic")
                    Picker("Mic", selection: $settings.screenMic) {
                        Text("Automatic (\(name(coordinator.automatic.screenMic, in: coordinator.audioDevices)))").tag(DeviceChoice.automatic)
                        deviceItems(coordinator.audioDevices, selected: settings.screenMic)
                        Divider()
                        Text("No mic").tag(DeviceChoice.none)
                    }
                    .labelsHidden()
                }
                GridRow {
                    RowLabel("Rate")
                    Text(coordinator.screenRateText)
                        .monospacedDigit()
                        .help("Not a setting: the screen records at 2× the camera rate, so a 23.976 timeline uses every other screen frame.")
                }
            }
            .disabled(!idle)

            HStack {
                Toggle("Show frame", isOn: Binding(get: { coordinator.frameShownWhileIdle },
                                                   set: { coordinator.setFrameShown($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!idle)
                Spacer()
                Button(coordinator.snapButtonTitle) { coordinator.snapNow() }
                    .lineLimit(1)
                    .help(coordinator.snapButtonHelp)
            }

            HStack(spacing: 4) {
                DisclosureArrow(isExpanded: $settings.screenOptionsShown, label: "screen options")
                Button { settings.screenOptionsShown.toggle() } label: { Text("Options").font(.callout) }
                    .buttonStyle(.plain)
                Spacer()
            }
            if settings.screenOptionsShown {
                ScreenOptions(coordinator: coordinator, resolved: resolved)
                    .padding(.leading, 18)
                    .disabled(!idle)
            }
        }
    }
}

/// The Screen options under the disclosure arrow: frame position, the checkboxes, and the
/// Parallels toolbar.
private struct ScreenOptions: View {
    @Bindable var coordinator: SessionCoordinator
    let resolved: DisplayInfo?

    var body: some View {
        @Bindable var settings = coordinator.settings
        let wholeDisplay = resolved.map { coordinator.resolvedPreset(for: $0).sizing == .fullDisplay } ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Frame position").foregroundStyle(.secondary)
                Picker("Frame position", selection: Binding(get: { coordinator.frameAnchor },
                                                            set: { coordinator.setFrameAnchor($0) })) {
                    Text("Bottom").tag(FrameAnchor.bottom)
                    Text("Top").tag(FrameAnchor.top)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(wholeDisplay || resolved == nil)
            }
            .help(wholeDisplay ? "The whole-display frame has no position."
                  : "Bottom keeps the strip under the menu bar free, for example for a window toolbar.")

            CheckboxWithNote("Record computer sound", note: "Sound from videos and apps, on its own track",
                             isOn: $settings.systemAudio)
            Toggle("Snap the front window into the frame on Start", isOn: $settings.snapOnStart)
            CheckboxWithNote("Hide other windows", note: "Records only the snapped app; menus it opens may be missing",
                             isOn: $settings.windowOnly)
            Toggle("Dim outside the frame", isOn: $settings.dimOutsideFrame)
            CheckboxWithNote("Hide the Parallels toolbar",
                             note: "Snaps Parallels Desktop with its toolbar above the frame, so only the VM screen is recorded",
                             isOn: $settings.hideParallelsToolbar)
            if settings.hideParallelsToolbar {
                Stepper(value: $settings.parallelsToolbarOffsetPt, in: RecorderSettings.parallelsToolbarOffsetRange, step: 1) {
                    Text("Toolbar offset: \(SessionRules.offsetLabel(settings.parallelsToolbarOffsetPt))")
                        .monospacedDigit()
                }
                .controlSize(.small)
                .padding(.leading, 20)
                .help("+ moves the Parallels window up: use it when a strip of its toolbar shows at the top of the recording. "
                      + "− moves it down: use it when the top of the VM screen is cut off. Snap again after a change.")
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// A checkbox with a short note under its title.
private struct CheckboxWithNote: View {
    let title: String
    let note: String
    @Binding var isOn: Bool

    init(_ title: String, note: String, isOn: Binding<Bool>) {
        self.title = title; self.note = note; self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(note)
    }
}

extension ScreenFramePreset {
    /// The short name for the Frame picker; the size in pixels shows next to it.
    var shortName: String {
        switch id {
        case ScreenFramePreset.laptop16x9.id: "16:9 frame"
        case ScreenFramePreset.fullDisplay.id: "Whole display"
        default: name
        }
    }

    /// The name inside "Automatic (…)", kept short so the size fits next to the picker.
    var autoName: String {
        switch id {
        case ScreenFramePreset.laptop16x9.id: "16:9"
        case ScreenFramePreset.fullDisplay.id: "whole display"
        default: name
        }
    }
}

/// Picker rows for a device list, plus a row for a saved device that is not connected.
@ViewBuilder
private func deviceItems(_ devices: [CaptureDeviceInfo], selected: DeviceChoice) -> some View {
    ForEach(devices) { d in
        Text(d.detail.map { "\(d.name) — \($0)" } ?? d.name).tag(DeviceChoice.device(uid: d.uid))
    }
    if case let .device(uid) = selected, !devices.contains(where: { $0.uid == uid }) {
        Text("Saved device (not connected)").tag(selected)
    }
}

private func name(_ uid: String?, in devices: [CaptureDeviceInfo]) -> String {
    guard let uid else { return "none" }
    return devices.first { $0.uid == uid }?.name ?? "none"
}

// MARK: - Preflight, Start/Stop, status

private struct IssuesList: View {
    let coordinator: SessionCoordinator

    var body: some View {
        // The Signal line shows the camera's size and its fix, so the not-4K warning is not repeated;
        // a banner at the top shows the USB link and empty frames.
        let inBanners = Set(coordinator.alerts.compactMap(\.issueID))
        let issues = coordinator.issues.filter { $0.id != "camera.not_4k" && !inBanners.contains($0.id) }
        if !issues.isEmpty, coordinator.state.canStart {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: issue.severity == .blocker ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .blocker ? Color.red : Color.orange)
                        Text(issue.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if issues.contains(where: { $0.id.hasPrefix("camera.effect") }) {
                    Button("Open Video Effects") { CaptureDevices.showVideoEffectsControls() }
                        .controlSize(.small)
                        .help("macOS shows this menu only while the camera is on. Turn on Live preview first.")
                }
            }
        }
    }
}

private struct RecordControls: View {
    let coordinator: SessionCoordinator
    let closeMenu: () -> Void

    var body: some View {
        let state = coordinator.state
        let recording = state == .recording
        Button {
            let starting = state.canStart
            coordinator.toggleRecording()
            if starting { closeMenu() }
        } label: {
            HStack {
                Image(systemName: recording ? "stop.fill" : "record.circle")
                Text(title)
                Spacer()
                Text(recording ? coordinator.elapsedText : HotKey.startStop.displayString)
                    .monospacedDigit()
                    .opacity(0.8)
            }
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(recording ? .red : .accentColor)
        .controlSize(.large)
        .disabled(state == .preparing || state == .stopping || (state.canStart && coordinator.hasBlockers))
    }

    private var title: String {
        switch coordinator.state {
        case .idle, .error: "Start Recording"
        case .preparing: "Starting…"
        case .recording: "Stop"
        case .stopping: "Saving…"
        }
    }
}

private struct StatusArea: View {
    let coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(coordinator.trackLines) { line in
                Label(line.text, systemImage: line.isProblem ? "exclamationmark.triangle.fill" : "circle.fill")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(line.isProblem ? Color.orange : Color.primary)
                    .symbolRenderingMode(.multicolor)
            }
            if coordinator.state == .recording {
                HStack {
                    Button { coordinator.flag() } label: { Label("Flag", systemImage: "flag.fill") }
                        .help(ControlBarRules.flagHelp(recording: true, lookbackS: coordinator.settings.flagLookbackSeconds))
                    ReplayButton(coordinator: coordinator)
                    Spacer()
                    Text(ControlBarRules.flagSummary(coordinator.markers.count)).font(.caption).foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
            if case let .error(message) = coordinator.state {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { coordinator.dismissError() }.controlSize(.small)
                }
            }
            if let notice = coordinator.notice {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
                        if let fix = coordinator.snapFix, coordinator.state.canStart {
                            Button(fix.buttonTitle) { coordinator.applySnapFix() }
                                .controlSize(.small)
                                .help("Moves the frame, then snaps the front window again.")
                        }
                    }
                    Spacer()
                    Button { coordinator.clearNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            }
            if let last = coordinator.lastSession, coordinator.state.canStart {
                LastSessionView(last: last, coordinator: coordinator)
            }
        }
    }
}

private struct LastSessionView: View {
    let last: LastSession
    let coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: last.status == .complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(last.status == .complete ? Color.green : Color.orange)
                Text(summary).font(.callout)
                Spacer()
                ReplayButton(coordinator: coordinator).controlSize(.small)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([last.folder]) }
                    .controlSize(.small)
            }
            if let note = CaptureAlerts.lastTakeMicNote(last.micSource) {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(last.errors.prefix(4).enumerated()), id: \.offset) { _, error in
                Text("• \(error)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if last.errors.count > 4 {
                Text("\(last.errors.count - 4) more in session.json").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        let verb = last.status == .complete ? "Saved" : "Saved with problems"
        let duration = last.durationS.map { " (\(SessionRules.elapsedString($0)))" } ?? ""
        return "\(verb): \(last.folder.lastPathComponent)\(duration)"
    }
}

/// Replay (or Close Replay): the replay window, like the control bar's button and ⌃⌥⌘P.
private struct ReplayButton: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let target = coordinator.replayTarget
        let shown = coordinator.replayShown
        Button { coordinator.toggleReplay() } label: {
            Label(shown ? "Close Replay" : "Replay", systemImage: "play.rectangle")
        }
        .help(ReplayRules.help(target, shown: shown))
        .disabled(!shown && target.folder == nil)
    }
}

// MARK: - Panels

private struct PermissionsPanel: View {
    let permissions: PermissionCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PermissionKind.allCases) { kind in
                let state = permissions.state(kind)
                HStack {
                    Image(systemName: kind.systemImage).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.title)
                        Text(kind.caption(state)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if state == .granted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button(state == .denied ? "Open Settings" : "Allow…") {
                            Task { await permissions.request(kind) }
                        }
                        .controlSize(.small)
                        if state == .notGranted {
                            Button {
                                permissions.openSettings(kind)
                            } label: { Image(systemName: "gear") }
                            .controlSize(.small)
                            .help("Open System Settings")
                        }
                    }
                }
            }
            Text("After you allow Screen Recording, quit and reopen TwinTake. Input Monitoring can need it too: "
                 + "the Keystrokes row says so.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OptionsPanel: View {
    @Bindable var settings: RecorderSettings
    /// Nothing records: while a take starts, records or saves, the codec, the bitrates and the
    /// folder stay as the take uses them, and Choose… (a modal panel that makes TwinTake the
    /// active app) never takes the keyboard from the recorded app.
    var idle: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                RowLabel("Codec")
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodec.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .disabled(!idle)
            }
            GridRow {
                RowLabel("Camera")
                Picker("Camera bitrate", selection: $settings.cameraBitrateMbps) {
                    ForEach(RecorderSettings.cameraBitratesMbps, id: \.self) { Text("\($0) Mbps").tag($0) }
                }
                .labelsHidden()
                .disabled(!idle || settings.codec == .proRes422LT)
            }
            GridRow {
                RowLabel("Screen")
                Picker("Screen bitrate", selection: $settings.screenBitrateMbps) {
                    ForEach(RecorderSettings.screenBitratesMbps, id: \.self) { Text("\($0) Mbps").tag($0) }
                }
                .labelsHidden()
                .disabled(!idle || settings.codec == .proRes422LT)
            }
            GridRow {
                RowLabel("Folder")
                HStack {
                    Text(abbreviated(settings.outputFolder))
                        .lineLimit(1).truncationMode(.middle)
                        .help(settings.outputFolder.path)
                    Spacer()
                    Button("Choose…") { chooseFolder() }.controlSize(.small)
                        .disabled(!idle)
                        .help(idle ? "Pick the folder for new recordings." : "Change the folder after Stop.")
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Show the session in Finder after Stop", isOn: $settings.revealInFinder)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder for new recordings."
        panel.directoryURL = settings.outputFolder
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { settings.outputFolder = url }
    }
}

/// "Control Bar": the Show control bar switch (visible with the section closed), and under the
/// arrow the pinned apps (reorder, remove), how far back Flag points, and the bar's place.
private struct ControlBarSettingsRow: View {
    @Bindable var coordinator: SessionCoordinator
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                DisclosureArrow(isExpanded: $isExpanded, label: "control bar settings")
                Button { isExpanded.toggle() } label: { Text("Control Bar").font(.headline) }
                    .buttonStyle(.plain)
                Spacer()
                Toggle("Show control bar", isOn: Binding(get: { coordinator.settings.showControlBar },
                                                         set: { coordinator.setControlBarShown($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .help("A small floating bar with Record / Stop, your pinned apps, Flag and the Mac mic meter. "
                          + "It is never recorded.")
            }
            if isExpanded {
                ControlBarSettingsPanel(coordinator: coordinator).padding(.leading, 18)
            }
        }
    }
}

private struct ControlBarSettingsPanel: View {
    @Bindable var coordinator: SessionCoordinator

    var body: some View {
        @Bindable var settings = coordinator.settings
        let apps = settings.pinnedApps
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned apps").font(.callout.weight(.semibold))
            if apps.isEmpty {
                Text("None yet. Click the app you record, then + on the control bar.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 6) {
                        Image(nsImage: AppIcons.icon(for: app.bundleID, side: 16))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.name).lineLimit(1)
                            Text(index < PinnedApps.maxVisible ? app.bundleID : "\(app.bundleID) · in the overflow menu")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button { coordinator.movePinnedApp(app, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Move \(app.name) to the left on the bar")
                        Button { coordinator.movePinnedApp(app, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == apps.count - 1)
                            .help("Move \(app.name) to the right on the bar")
                        Button { coordinator.removePinnedApp(app) } label: { Image(systemName: "xmark") }
                            .help("Remove \(app.name) from the bar")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Text("One click on an app's button brings it forward and snaps its front window into the frame. "
                 + "More than \(PinnedApps.maxVisible) go into a menu at the end of the bar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Flag looks back").foregroundStyle(.secondary)
                Picker("Flag looks back", selection: $settings.flagLookbackSeconds) {
                    ForEach(ControlBarRules.lookbackChoices, id: \.self) { Text(ControlBarRules.lookbackLabel($0)).tag($0) }
                    if !ControlBarRules.lookbackChoices.contains(settings.flagLookbackSeconds) {
                        Text(ControlBarRules.lookbackLabel(settings.flagLookbackSeconds)).tag(settings.flagLookbackSeconds)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("A flag (\(HotKey.flag.displayString)) says: something in this time before it was wrong. "
                      + "events.jsonl stores it as lookback_s.")
            }
            Button("Move Bar to the Default Place") { coordinator.resetControlBarPosition() }
                .controlSize(.small)
                .help("The strip above the frame on the recording display, else under the menu bar. "
                      + "Drag the bar anywhere; it remembers its place on each display.")
        }
    }
}

/// "Keystrokes": when the pill shows (visible with the section closed), and under the arrow
/// whether it is in screen.mov and how it names keys.
private struct KeystrokeSettingsRow: View {
    @Bindable var coordinator: SessionCoordinator
    @Binding var isExpanded: Bool

    var body: some View {
        @Bindable var settings = coordinator.settings
        let inputMonitoring = coordinator.permissions.state(.inputMonitoring) == .granted
        let note = KeystrokeRules.accessibilityNote(mode: settings.keystrokeMode,
                                                    accessibilityGranted: coordinator.permissions.state(.accessibility) == .granted,
                                                    inputMonitoringGranted: inputMonitoring,
                                                    tapProven: coordinator.keystrokeTapProven)
            ?? (settings.keystrokeMode == .off ? nil : coordinator.keystrokeSecureInputNote ?? coordinator.keystrokeTapNote)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                DisclosureArrow(isExpanded: $isExpanded, label: "keystroke settings")
                Button { isExpanded.toggle() } label: { Text("Keystrokes").font(.headline) }
                    .buttonStyle(.plain)
                Spacer()
                Picker("Show keystrokes", selection: $settings.keystrokeMode) {
                    ForEach(KeystrokeMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Shows shortcuts (⇧⌘P, Ctrl+Shift+P) and keys such as Return or Esc in a pill at the bottom of the frame. "
                      + "Typed text never shows.")
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    CheckboxWithNote("Include keystrokes in screen.mov",
                                     note: "The pill is recorded like the screen. TwinTake's other windows never are",
                                     isOn: $settings.keystrokesInScreen)
                        .toggleStyle(.checkbox)
                        .disabled(!coordinator.state.canStart)
                    HStack {
                        Text("Key names").foregroundStyle(.secondary)
                        Picker("Key names", selection: $settings.keyNameStyle) {
                            ForEach(KeyNameStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("Auto uses Windows names (Ctrl+Shift+P) while a Parallels VM is in front, else Mac symbols (⇧⌘P). "
                         + "Typed text, ⇧ with a letter and secure fields never show.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(KeystrokeRules.sourceCaption(inputMonitoringGranted: inputMonitoring,
                                                      tapProven: coordinator.keystrokeTapProven))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
    }
}

private struct ShortcutsPanel: View {
    let errors: [HotKeyAction: String]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(HotKeyAction.allCases, id: \.self) { action in
                GridRow {
                    Text(action.defaultHotKey.displayString).monospaced().gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(action.title)
                        if let error = errors[action] {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
}
