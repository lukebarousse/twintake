import CoreGraphics

/// How `WindowSnapper` places a window on the frame.
public enum SnapPlacement: String, Sendable, Hashable {
    /// The whole window covers the frame. Every app that has no profile.
    case fill
    /// The window's content area covers the frame exactly. Its title bar and toolbar sit just
    /// above the frame's top edge, outside the recording.
    case toolbarAbove = "toolbar_above"
}

/// Snap behavior for one app, keyed by bundle id. Plain data: no Accessibility calls.
public struct SnapProfile: Sendable, Hashable, Identifiable {
    /// Short id for events.jsonl, e.g. "parallels".
    public var id: String
    public var appName: String
    /// Bundle ids of the processes that own the windows (`NSRunningApplication.bundleIdentifier`).
    public var bundleIDs: Set<String>
    /// Bundle id prefixes that also match, e.g. "com.parallels.winapp." for every Parallels VM helper.
    public var bundleIDPrefixes: [String]
    public var placement: SnapPlacement
    /// Toolbar strip height (points) when the Accessibility API shows nothing usable.
    public var fallbackToolbarHeightPt: CGFloat

    public init(id: String, appName: String, bundleIDs: Set<String>, bundleIDPrefixes: [String] = [],
                placement: SnapPlacement, fallbackToolbarHeightPt: CGFloat = 0) {
        self.id = id; self.appName = appName; self.bundleIDs = bundleIDs; self.bundleIDPrefixes = bundleIDPrefixes
        self.placement = placement; self.fallbackToolbarHeightPt = fallbackToolbarHeightPt
    }

    /// True when `bundleID` is one of `bundleIDs` or starts with one of `bundleIDPrefixes`.
    public func matches(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleIDs.contains(bundleID) || bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Every app without a profile: the window fills the frame.
    public static let standard = SnapProfile(id: "standard", appName: "Any app", bundleIDs: [], placement: .fill)

    /// Parallels Desktop windows: only the VM screen is in the frame.
    ///
    /// The process that owns the VM window is not always the one in the menu bar, so every
    /// Parallels Desktop process that can show a VM window matches. Seen on Luke's Mac (Parallels
    /// Desktop 27, "Windows 11" VM):
    /// - `com.parallels.desktop.console` (`Parallels Desktop.app`, `prl_client_app`, a regular
    ///   app) owns the windowed VM window: the window list shows the 1192x703 "Windows 11" window
    ///   under this process.
    /// - `com.parallels.winapp.<vm uuid>.VM` (`<VM>.pvm/VM.app`, `WinAppHelper`) runs twice: the
    ///   "Windows 11 Dock Helper" (a regular app; the menu bar then shows "Windows 11") and the
    ///   "Windows 11 Coherence Helper" (`LSUIElement`), which owns the Coherence windows.
    /// - `com.parallels.winapp.<app hash>.<vm uuid>`: the Windows app stubs in
    ///   `~/Applications (Parallels)`, which can own Coherence windows too.
    /// - `com.parallels.vm` (`Parallels VM.app`, `prl_vm_app`) runs the VM and shows no window;
    ///   `com.parallels.macvm` (`Parallels Mac VM.app`) runs a macOS VM.
    ///
    /// Other Parallels products (Parallels Toolbox `com.parallels.toolbox`, Parallels Client) and
    /// the background helpers (`com.parallels.desktop.dispatcher`, the mounter) do not match:
    /// their windows have no VM toolbar and fill the frame like any app.
    ///
    /// A window without a Parallels toolbar (Coherence) measures as "no title bar", so it still
    /// fills the frame.
    ///
    /// Fallback 38 pt: the VM window toolbar is an `NSToolbar` (unified compact style). Measured on
    /// Luke's Mac: the VM window was 1504x846 pt (window list) while the VM display mode was
    /// 3008x1616 px at 2x = 1504x808 pt (`parallels.log` `SetMode`), so the strip is 846 - 808 = 38 pt.
    public static let parallelsDesktop = SnapProfile(
        id: "parallels", appName: "Parallels Desktop",
        bundleIDs: ["com.parallels.desktop.console", "com.parallels.vm", "com.parallels.macvm"],
        bundleIDPrefixes: ["com.parallels.winapp."], placement: .toolbarAbove, fallbackToolbarHeightPt: 38)

    /// The built-in profiles.
    public static let all: [SnapProfile] = [.parallelsDesktop]

    /// The profile for `bundleID` in `profiles`, else `.standard`.
    public static func profile(forBundleID bundleID: String?, in profiles: [SnapProfile] = all) -> SnapProfile {
        profiles.first { $0.matches(bundleID) } ?? .standard
    }
}

// MARK: - Toolbar height

/// One element of a window's Accessibility tree, as the toolbar detection reads it.
public struct AXElementInfo: Sendable, Hashable {
    public var role: String
    public var subrole: String?
    /// Global CG points (top-left origin, y down), like the window frame.
    public var frame: CGRect

    public init(role: String, subrole: String? = nil, frame: CGRect) {
        self.role = role; self.subrole = subrole; self.frame = frame
    }
}

/// Where a toolbar height came from.
public enum ToolbarHeightSource: String, Sendable, Hashable {
    /// The top edge of the largest element that spans the window's width down to its bottom
    /// edge: the content area (the VM screen).
    case contentElement = "content_element"
    /// The bottom edge of the window's `AXToolbar`.
    case toolbarElement = "toolbar_element"
    /// Twice the distance from the window top to the center of the close button. macOS centers
    /// the window buttons in the title bar or unified toolbar strip.
    case titleBarButtons = "title_bar_buttons"
    /// Nothing usable in the Accessibility tree: the profile's fallback height.
    case fallback
    /// The window has no macOS title bar and no toolbar (a Coherence window): nothing goes above
    /// the frame.
    case noTitleBar = "no_title_bar"
}

/// A detected toolbar strip height, with the app's fine-tune offset.
public struct ToolbarMeasurement: Sendable, Hashable {
    /// What the detection found (points).
    public var detectedPt: CGFloat
    public var source: ToolbarHeightSource
    /// Points the app adds to the detected height. Can be negative.
    public var fineTunePt: CGFloat

    public init(detectedPt: CGFloat, source: ToolbarHeightSource, fineTunePt: CGFloat = 0) {
        self.detectedPt = detectedPt; self.source = source; self.fineTunePt = fineTunePt
    }

    /// The height the snapper uses: detected plus fine-tune, never below 0.
    public var heightPt: CGFloat { max(0, detectedPt + fineTunePt) }

    /// True when the height came from an element of the window (content area, toolbar or window
    /// buttons). False for the fallback and for "no title bar".
    public var isMeasured: Bool {
        switch source {
        case .contentElement, .toolbarElement, .titleBarButtons: true
        case .fallback, .noTitleBar: false
        }
    }
}

/// Finds the height of the strip above a window's content area (title bar plus toolbar).
public enum ToolbarDetection {
    /// Heights outside this range are not a toolbar strip (points).
    public static let plausibleRange: ClosedRange<CGFloat> = 12...160
    /// How far an edge may be from the window's edge and still count as on it (points).
    static let edgeSlack: CGFloat = 2
    /// A content element spans at least this part of the window's width.
    static let minContentWidthShare: CGFloat = 0.9

    /// Roles that are never the content area.
    static let controlRoles: Set<String> = [
        "AXButton", "AXToolbar", "AXStaticText", "AXImage", "AXMenuButton", "AXPopUpButton", "AXTextField",
        "AXCheckBox", "AXRadioButton", "AXSlider", "AXMenuBar", "AXMenu", "AXMenuItem", "AXSegmentedControl",
        "AXIncrementor", "AXProgressIndicator", "AXBusyIndicator", "AXComboBox", "AXSearchField",
    ]
    static let windowButtonSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    ]

    /// The toolbar strip height of a window.
    ///
    /// Order: the content element, then the larger of the toolbar's bottom edge and the window
    /// buttons' estimate, then `fallbackPt`. A window without window buttons and without a
    /// toolbar has no strip (0). `elements == nil` means the Accessibility tree could not be read,
    /// so the fallback applies.
    /// - Parameters:
    ///   - window: the window frame, global CG points.
    ///   - elements: the window's Accessibility elements (any depth), global CG points.
    ///   - fallbackPt: the profile's fallback height.
    ///   - fineTunePt: the app's offset, added to the result.
    public static func measure(window: CGRect, elements: [AXElementInfo]?, fallbackPt: CGFloat,
                               fineTunePt: CGFloat = 0) -> ToolbarMeasurement {
        func result(_ pt: CGFloat, _ source: ToolbarHeightSource) -> ToolbarMeasurement {
            ToolbarMeasurement(detectedPt: (pt * 2).rounded() / 2, source: source, fineTunePt: fineTunePt)
        }
        guard let elements, window.width > 0, window.height > 0 else { return result(fallbackPt, .fallback) }

        if let content = contentElement(window: window, elements: elements) {
            return result(content.minY - window.minY, .contentElement)
        }

        let toolbarBottom = elements
            .filter { $0.role == "AXToolbar" && $0.frame.minY >= window.minY - edgeSlack }
            .map { $0.frame.maxY - window.minY }
            .filter { plausibleRange.contains($0) }
            .max()
        let buttons = elements
            .filter { $0.subrole.map(windowButtonSubroles.contains) ?? false }
            .map { 2 * ($0.frame.midY - window.minY) }
            .filter { plausibleRange.contains($0) }
            .max()
        switch (toolbarBottom, buttons) {
        case let (t?, b?): return t >= b ? result(t, .toolbarElement) : result(b, .titleBarButtons)
        case let (t?, nil): return result(t, .toolbarElement)
        case let (nil, b?): return result(b, .titleBarButtons)
        case (nil, nil): break
        }

        let hasTitleBar = elements.contains { $0.role == "AXToolbar" || ($0.subrole.map(windowButtonSubroles.contains) ?? false) }
        return hasTitleBar ? result(fallbackPt, .fallback) : result(0, .noTitleBar)
    }

    /// The largest element that spans the window's width, ends at its bottom edge and starts a
    /// plausible strip below its top edge.
    static func contentElement(window: CGRect, elements: [AXElementInfo]) -> CGRect? {
        let candidates = elements.filter { e in
            let f = e.frame
            guard !controlRoles.contains(e.role), f.width > 0, f.height > 0 else { return false }
            return f.width >= window.width * minContentWidthShare
                && f.minX >= window.minX - edgeSlack && f.maxX <= window.maxX + edgeSlack
                && abs(f.maxY - window.maxY) <= edgeSlack
                && plausibleRange.contains(f.minY - window.minY)
        }
        return candidates.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.frame
    }
}

// MARK: - Toolbar-above placement

/// Geometry for `SnapPlacement.toolbarAbove`. Global CG points (top-left origin, y down).
public enum ToolbarAboveGeometry {
    /// The window frame that puts the content area (the window minus its top `toolbarPt`)
    /// exactly on `frame`.
    public static func windowFrame(for frame: CGRect, toolbarPt: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY - toolbarPt, width: frame.width, height: frame.height + toolbarPt)
    }

    /// The content area of a window whose top `toolbarPt` is the toolbar strip.
    public static func contentFrame(ofWindow window: CGRect, toolbarPt: CGFloat) -> CGRect {
        let t = min(max(0, toolbarPt), window.height)
        return CGRect(x: window.minX, y: window.minY + t, width: window.width, height: window.height - t)
    }

    /// How many whole points the frame must move down so the toolbar fits below `topLimitY`
    /// (the bottom of the menu bar), or nil when it fits.
    public static func roomNeeded(frame: CGRect, toolbarPt: CGFloat, topLimitY: CGFloat,
                                  tolerance: CGFloat = 0.5) -> CGFloat? {
        let short = topLimitY - (frame.minY - toolbarPt)
        return short > tolerance ? short.rounded(.up) : nil
    }
}

/// What a toolbar-above snap does: place the window, or refuse because the toolbar would sit in
/// the menu bar.
public enum ToolbarAbovePlan: Sendable, Equatable {
    /// Move the window here (global CG points).
    case place(window: CGRect)
    /// The toolbar does not fit between the menu bar and the frame. The frame must move down by
    /// this many points (or go to the bottom of the display).
    case noRoom(moveDownPt: CGFloat)

    /// - Parameters:
    ///   - frame: the recording frame, global CG points.
    ///   - toolbarPt: the toolbar strip height (fine-tune included).
    ///   - topLimitY: the lowest y the window top may reach (`DisplayInfo.windowTopLimitGlobal`);
    ///     nil skips the check.
    public static func make(frame: CGRect, toolbarPt: CGFloat, topLimitY: CGFloat?) -> ToolbarAbovePlan {
        if let topLimitY, let down = ToolbarAboveGeometry.roomNeeded(frame: frame, toolbarPt: toolbarPt, topLimitY: topLimitY) {
            return .noRoom(moveDownPt: down)
        }
        return .place(window: ToolbarAboveGeometry.windowFrame(for: frame, toolbarPt: toolbarPt))
    }

    /// The one correction after the read-back: the window frame to ask for again, or nil when
    /// the content area is within `tolerance` of `frame` on every edge.
    public static func correction(frame: CGRect, achievedWindow: CGRect, toolbarPt: CGFloat,
                                  tolerance: CGFloat) -> CGRect? {
        let content = ToolbarAboveGeometry.contentFrame(ofWindow: achievedWindow, toolbarPt: toolbarPt)
        if content.isClose(to: frame, tolerance: tolerance) { return nil }
        return ToolbarAboveGeometry.windowFrame(for: frame, toolbarPt: toolbarPt)
    }
}
