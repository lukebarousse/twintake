// WindowTools: display geometry, window snapping, the frame overlay and global hotkeys.
//
// - `Displays` / `DisplayInfo`: connected displays and the recording frame on each.
// - `WindowSnapper`: moves the front window into the frame (Accessibility permission).
// - `SnapTargetFinder`: picks that window from the window list: the front-most app window on
//   the recording display, never the recorder's own, the desktop or a window on another display.
//   `SnapTargetFinder.findApp` picks a pinned app's front window for the control bar's app buttons
//   (a Parallels VM's own window first), and `cameForward` says when the app came forward.
// - `SnapProfile`: per-app placement by bundle id. Parallels Desktop keeps its toolbar above the
//   frame (`ToolbarDetection`, `ToolbarAbovePlan`), so only the VM screen is recorded.
// - `DockOverlap`: warns when a visible Dock covers part of the frame.
// - `SnappedWindowMonitor`: reports when that window moves while recording.
// - `FrameOverlay`: dims the display outside the frame and draws a border around it, at the
//   floating level; the camera window and the control bar sit just above it (`aboveOverlayLevel`).
// - `CameraWindowGeometry`, `ControlBarGeometry`: where the camera window and the control bar
//   open, and how they stay on screen.
// - `GlobalHotKeys` / `HotKey`: Carbon hotkeys (no permission needed).
//
// Coordinates follow `FrameGeometry` in RecorderCore: global CG points (top-left origin) unless
// a name says local or AppKit.
