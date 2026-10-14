import RecorderCore
import SwiftUI

// The level meters, the banners, the Mic check controls and the mic warning calibration. Every
// view reads the coordinator's plain data only (`meters` is a copy of the level monitor's
// snapshot), so none of them touches a capture object or waits for a capture queue. The views
// that read `meters` are small, so the 20 Hz poll redraws only them.

extension MeterScale.Zone {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }
}

extension MicTone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .good: .green
        case .warning: .orange
        }
    }

    var systemImage: String {
        switch self {
        case .neutral: "info.circle"
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Meters

/// One meter: the last block's peak, green up to -12 dBFS, yellow up to -3 dBFS, red above, and a
/// tick at the 1.5 s peak hold. Empty for a source that sends nothing.
struct LevelMeterBar: View {
    let level: AudioLevel?
    var vertical = false
    var trackColor = Color.secondary.opacity(0.22)

    var body: some View {
        Canvas { context, size in
            let length = vertical ? size.height : size.width
            let thickness = vertical ? size.width : size.height
            let whole = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: min(2, thickness / 2))
            context.fill(whole, with: .color(trackColor))
            guard let level, level.isLive else { return }
            context.clip(to: whole)
            // A stretch of the bar from fraction a to fraction b (vertical: from the bottom up).
            func stretch(_ a: Double, _ b: Double) -> CGRect {
                let start = CGFloat(a) * length, end = CGFloat(b) * length
                return vertical ? CGRect(x: 0, y: size.height - end, width: size.width, height: end - start)
                    : CGRect(x: start, y: 0, width: end - start, height: size.height)
            }
            let peak = MeterScale.fraction(level.peakDb)
            for segment in MeterScale.segments where peak > segment.from {
                context.fill(Path(stretch(segment.from, min(peak, segment.to))), with: .color(segment.zone.color))
            }
            let hold = MeterScale.fraction(level.peakHoldDb)
            if hold > 0 {
                let tick = 2 / max(length, 1)
                let at = min(max(hold - tick, 0), 1 - tick)
                context.fill(Path(stretch(at, at + tick)), with: .color(MeterScale.zone(level.peakHoldDb).color))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(level.map { $0.isLive ? "\(MeterScale.label($0)) dBFS" : "no signal" } ?? "no signal")
    }
}

/// A labeled horizontal meter for the menu: "Camera mic [bar] -18 CLIP".
struct MeterRow: View {
    let title: String
    let level: AudioLevel?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            LevelMeterBar(level: level)
                .frame(height: 7)
            Text(MeterScale.label(level))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            let clips = level?.clipCount ?? 0
            Text("CLIP")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
                .opacity(clips > 0 ? 1 : 0)
                .help(clips > 0 ? "\(clips) samples at or above -1 dBFS since the start (before recording: in the last 1.5 s)" : "")
        }
        .accessibilityElement(children: .combine)
    }
}

/// The meters of the take, the mic check or the idle preview, and the camera mic detector's line
/// under them.
struct LevelMetersPanel: View {
    let coordinator: SessionCoordinator
    var showsDetector = true

    var body: some View {
        let meters = coordinator.meters
        let sources = coordinator.meterSources
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sources, id: \.self) { source in
                MeterRow(title: source.meterTitle, level: meters?[source])
            }
            if showsDetector, sources.contains(.cameraMic), let status = meters?.detector {
                let macMicMissing = !sources.contains(.screenMic) && MicCalibrationText.needsMacMic(coordinator.settings.micCalibration)
                MicTextLine(text: MicStatusText.live(status, macMicMissing: macMicMissing), font: .caption)
            }
        }
    }
}

/// One line of mic text with its icon.
struct MicTextLine: View {
    let text: MicText
    var font: Font = .callout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(text.title).font(font).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: text.tone.systemImage).foregroundStyle(text.tone.color)
            }
            if let detail = text.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
        }
    }
}

// MARK: - Banners

/// A banner in the menu: red when it blocks Start, orange for a warning.
struct AlertBanner: View {
    let alert: CaptureAlert
    var reconnect: (() -> Void)?
    var reconnecting = false

    var body: some View {
        let tint = alert.blocksStart ? Color.red : Color.orange
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: alert.blocksStart ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let detail = alert.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let reconnect {
                    Button(reconnecting ? "Reconnecting…" : "Reconnect Camera", action: reconnect)
                        .controlSize(.small)
                        .disabled(reconnecting)
                        .help("Closes the camera and opens it again, like a replug. Only while nothing records.")
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

/// Every banner, at the top of the menu.
struct AlertBannerList: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let alerts = coordinator.alerts
        if !alerts.isEmpty {
            VStack(spacing: 6) {
                ForEach(alerts) { alert in
                    AlertBanner(alert: alert,
                                reconnect: alert.offersReconnect ? { coordinator.reconnectCamera() } : nil,
                                reconnecting: coordinator.cameraReconnecting)
                }
            }
        }
    }
}

/// The banner in the camera window: solid, so it reads over any picture. Its Reconnect button
/// is a native button of the window (`CameraMonitorContainer`), which takes a click without
/// making TwinTake active.
struct WindowAlertBanner: View {
    let alert: CaptureAlert
    var reconnecting = false

    var body: some View {
        let foreground: Color = alert.blocksStart ? .white : .black
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: alert.blocksStart ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text(alert.title).font(.caption.weight(.semibold)).lineLimit(3)
                if let detail = reconnecting ? "Reconnecting…" : alert.detail {
                    Text(detail).font(.caption2).lineLimit(2).opacity(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((alert.blocksStart ? Color.red : Color.orange).opacity(0.93), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mic check

/// "Mic check · 7 s left · talk now", counting down on its own.
struct MicCheckCountdown: View {
    let progress: MicCheckProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            Text(progress.cancelling ? "Closing the mics…" : "Mic check · \(progress.secondsLeft(at: context.date)) s left · talk now")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// The Mic check row in the Camera section: the button, then the meters and the live verdict
/// while it runs, then its result.
struct MicCheckControls: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let check = coordinator.micCheck
        let reason = coordinator.micCheckUnavailableReason
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let check, check.purpose == .check {
                    Button("Cancel") { coordinator.cancelMicCheck() }
                        .disabled(check.cancelling)
                    MicCheckCountdown(progress: check)
                } else {
                    Button {
                        coordinator.startMicCheck()
                    } label: {
                        Label("Mic Check", systemImage: "mic")
                    }
                    .disabled(reason != nil)
                    .help(reason ?? "Listens to the camera mic and the Mac mic for 10 s. Talk: it says whether the camera hears the \(MicNames.external). It uses the live meters while the camera preview is on; otherwise it opens the mics for the 10 s only.")
                    Text("Talk for 10 s to check the camera mic.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            if check?.purpose == .check {
                LevelMetersPanel(coordinator: coordinator)
            } else if let outcome = coordinator.micCheckOutcome {
                HStack(alignment: .firstTextBaseline) {
                    MicTextLine(text: MicStatusText.outcome(outcome), font: .callout)
                    Spacer(minLength: 0)
                    Button { coordinator.dismissMicCheckOutcome() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .accessibilityLabel("Dismiss the mic check result")
                }
            }
        }
    }
}

// MARK: - Calibration

/// "Mic warning" in Recording Settings: the rules in use, "Calibrate Mic Warning…" and Reset, and
/// the two-sample flow.
struct MicCalibrationPanel: View {
    let coordinator: SessionCoordinator

    var body: some View {
        let calibration = coordinator.settings.micCalibration
        VStack(alignment: .leading, spacing: 6) {
            Text("Mic warning").font(.callout.weight(.semibold))
            if let flow = coordinator.calibrationFlow {
                CalibrationSteps(coordinator: coordinator, flow: flow)
            } else {
                Text(calibration == nil ? "Warns when the camera records with its built-in mic." : "Calibrated with your two samples.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(MicCalibrationText.rules(calibration), id: \.self) { line in
                    Text(line).font(.caption).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(calibration == nil ? "Calibrate Mic Warning…" : "Calibrate Again…") { coordinator.beginCalibration() }
                        .help("Two 10 s samples: one with the \(MicNames.external) plugged in, one without. The thresholds go between them.")
                    if calibration != nil {
                        Button("Reset") { coordinator.resetCalibration() }
                            .help("Back to the default rule: camera L/R correlation below \(MicStatusText.correlation(MicFeatureRule.defaultCorrelation.threshold)).")
                    }
                }
                .controlSize(.small)
                .disabled(!coordinator.state.canStart)
            }
        }
    }
}

private struct CalibrationSteps: View {
    let coordinator: SessionCoordinator
    let flow: MicCalibrationFlow

    var body: some View {
        let running = coordinator.micCheck.flatMap { $0.purpose.isCalibration ? $0 : nil }
        VStack(alignment: .leading, spacing: 6) {
            Text(flow.instruction).font(.caption).fixedSize(horizontal: false, vertical: true)
            if let plugged = flow.plugged {
                Text("Sample 1, \(MicNames.external) plugged in: \(MicCalibrationText.sample(plugged))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let unplugged = flow.unplugged, flow.step == .review {
                Text("Sample 2, unplugged: \(MicCalibrationText.sample(unplugged))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let running {
                HStack(spacing: 8) {
                    Button("Cancel") { coordinator.cancelMicCheck() }.disabled(running.cancelling)
                    MicCheckCountdown(progress: running)
                }
                .controlSize(.small)
                LevelMetersPanel(coordinator: coordinator, showsDetector: false)
            } else if flow.step == .review {
                if let calibration = flow.calibration {
                    ForEach(MicCalibrationText.rules(calibration), id: \.self) { line in
                        Text(line).font(.caption.weight(.medium)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    if flow.calibration != nil {
                        Button("Save Calibration") { coordinator.saveCalibration() }.buttonStyle(.borderedProminent)
                    }
                    Button("Start Over") { coordinator.restartCalibration() }
                    Button("Cancel") { coordinator.cancelCalibration() }
                }
                .controlSize(.small)
            } else {
                let reason = coordinator.micCheckUnavailableReason
                HStack {
                    Button(flow.step == .plugged ? "Record Sample 1" : "Record Sample 2") { coordinator.recordCalibrationSample() }
                        .disabled(reason != nil)
                        .help(reason ?? "A 10 s mic check. Talk the whole time.")
                    Button("Cancel") { coordinator.cancelCalibration() }
                }
                .controlSize(.small)
            }
            if let error = flow.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
