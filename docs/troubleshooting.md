# Troubleshooting

Start with the menu. Each red item blocks Start, and each orange item is a warning. Each item says what to do.

- [The preview is green or empty](#the-preview-is-green-or-empty)
- [The Signal line says 1080p](#the-signal-line-says-1080p)
- [Mic warnings](#mic-warnings)
- [Menu bar indicators](#menu-bar-indicators)
- [Start is blocked](#start-is-blocked)
- [Snap does not move the window](#snap-does-not-move-the-window)
- [The take stopped by itself](#the-take-stopped-by-itself)
- [Shortcuts do nothing](#shortcuts-do-nothing)
- [macOS asks for the permissions again](#macos-asks-for-the-permissions-again)
- [Crashes and logs](#crashes-and-logs)

## The preview is green or empty

**"Cam Link is connected at USB 2 speed."** (red banner, Start blocked)

After an HDMI change, the Cam Link 4K can come back on its USB 2 lane. It still offers 4K, but it sends empty frames (a solid green picture).

1. Unplug the Cam Link and plug it back in. Reconnect Camera does not fix this case.
2. If it comes back, use another USB 3 port, cable or hub. See [setup.md](setup.md#capture-card-on-usb-3).

This banner comes before the other camera banners.

**"No picture: the Cam Link is sending empty frames."** (red banner on a USB 3 link)

1. Click **Reconnect Camera** in the banner, or right-click the camera window > **Reconnect Camera**. It works only while nothing records.
2. If the camera does not open again within 20 s, Reconnect works again and the notice says to replug. Unplug the capture card and plug it back in.

Start is blocked while the frames are empty. During a take the banner is orange: "camera.mov has no picture. Stop, then reconnect or replug the Cam Link."

The same banner in orange, as a warning only, means one flat color everywhere: a lens cap, a dark room or a camera menu.

The Cam Link sends about 12 all-zero frames each time its stream starts. TwinTake ignores the frames in the first second after each open, so this burst never triggers the banner.

**"No picture from the camera"** (camera window)

The camera sends no frames. Check the HDMI cable and the camera's HDMI output. Then open the menu, or hide and show the window, to try again.

**"The camera does not answer. Unplug it and plug it back in."**

The camera did not answer preflight within 5 s. TwinTake also reopens it once by itself.

**"… is in use by another app."**

Another app uses the camera. Close it (for example OBS, FaceTime or Zoom) if the picture freezes.

## The Signal line says 1080p

The orange line reads "1080p · 1920×1080 · 23.976 fps", with "Camera sends 1080p. Set the a6600 HDMI output to 4K 24p." under it. If you start anyway, camera.mov records 1080p.

1. Set the camera's HDMI output to 4K. See the [a6600 example](setup.md#worked-example-sony-a6600-at-4k-23976).
2. If a splitter sits between the camera and the capture card, connect the camera straight to the capture card and check again. See [HDMI splitters and EDID](setup.md#hdmi-splitters-and-edid).
3. Use an HDMI cable that carries 4K.

Other Signal lines:

- **"No signal"**: the capture card gets no HDMI picture. Check that the camera is on and its HDMI cable is in.
- **"Not connected"**: the picked camera is not connected.
- A Cam Link on USB 2 is blocked at 1080p too, because it sends uncompressed video.

If the signal changes during a take, the icon turns orange. camera.mov keeps the size and the rate it started with, so it misses or repeats frames after the change. Stop, then start again.

## Mic warnings

**"Rode not detected — the camera is using its built-in mic."**

1. Check that the external mic is in the camera's mic jack.
2. Talk. The warning goes away within about 15 s of clear voice.
3. If the warning shows while the external mic is plugged in, or does not show without it, calibrate the warning. See [Calibrate the mic warning](guide.md#calibrate-the-mic-warning).

**"The camera mic isn't picking up your voice."**

The Mac mic hears your voice, but the camera audio stays silent.

1. Check that the external mic is switched on.
2. Some cameras send silence after the mic is unplugged, instead of using their built-in mic. Pull the plug out of the camera's mic jack itself, wait 30 s, and check again.
3. Check that Camera > Audio is the camera's own audio input. Automatic picks it.

**Other mic problems:**

- **The warning beeps at the start of a take, with the external mic plugged in and on:** that is a false warning. Calibrate the mic warning. See [Calibrate the mic warning](guide.md#calibrate-the-mic-warning).
- **"The laptop lid is closed, so … records silence":** open the lid, or pick another Mic under Screen.
- **"The mic warning needs the Mac mic…":** your calibration tells the mics apart by level, so it needs the Mac mic. Pick a Mic under Screen.
- **"Mic Mode is … so macOS may process the camera audio":** pick Standard in Control Center > Mic Mode.
- **The Saved line says camera.mov used the built-in mic:** the warning was on for some of the take. session.json `mic_source` has the details.

## Menu bar indicators

macOS shows privacy indicators in the menu bar when an app uses the camera, a mic or the screen. TwinTake causes them in these cases:

| Indicator | When TwinTake shows it |
|---|---|
| Green camera | The camera is open: the camera window shows, the menu is open with Live preview on, or a take starts, records or saves. |
| Orange microphone | A mic is open: the meters with the camera preview, a mic check, or a take. In Camera mode the Mac mic is open during the take too, for the mic warning. |
| Purple screen recording | During a take in Screen or Both mode. Nothing captures the screen while idle. |

- The camera and the mics close about 1.5 s after nothing shows the camera. Both indicators then go off.
- When the display sleeps or the screen locks, they close at once.
- Without the microphone permission, the preview shows only the green indicator.
- If an indicator stays on with nothing shown, open Control Center to see which app uses the camera or the mic.
- Do not stop the screen recording from the macOS menu bar during a take. screen.mov then ends early.

**The TwinTake icon is orange:**

- **Idle:** the camera has trouble (USB 2, empty frames) or the mic warning is on. Open the menu.
- **While recording, with a beep:** a file ended early, the camera sends no picture, the camera signal changed, or the camera mic warns. Open the menu.

## Start is blocked

A red item in the menu blocks Start. The control bar's Record button is orange, and its tooltip says why. A click on it beeps and shows "Not ready: open the menu".

| Message starts with | Fix |
|---|---|
| "Only … free on the recording disk" | Free some space, or pick another folder in Recording Settings. Start needs about 10 minutes of recording time on the disk. |
| "The disk … is not connected" | Connect the disk, or pick another folder. |
| "TwinTake cannot write to …" | Pick another folder. |
| "Camera access is off" or "Microphone access is off" | Turn the permission on. See [setup.md](setup.md#permissions). |
| "… is on: …" (a video effect) | Click **Open Video Effects** and turn the effect off. Turn on Live preview first: macOS shows the menu only while the camera is on. |
| "… reports no video formats" | Check that the camera is on and its HDMI cable is in. |

## Snap does not move the window

- **Check Accessibility.** TwinTake moves windows with the Accessibility API. Allow it under Permissions.
- **"No window to snap on …":** the window is on another display. TwinTake never moves windows on other displays. Move the window onto the frame's display, then snap again.
- **The notice names the window and says it "did not respond" or "cannot be moved":** the app did not answer. Try again, or move the window by hand.
- **Parallels with the top frame:** the toolbar does not fit under the menu bar. Click **Move Frame to Bottom**.
- **A control bar button shows "… not in front":** macOS did not bring the app forward, so TwinTake did not move its window. Click the app once, then click its button again.
- **"… is not installed":** the pinned app is gone. Right-click its button and remove it.

## Keystrokes do not show

- **Check Accessibility.** TwinTake sees other apps' keys with the Accessibility permission. The Keystrokes row in the menu says when it is off. Allow it under Permissions; the pill works within a few seconds.
- **Check the setting.** Menu > Keystrokes is Off, or While recording while nothing records.
- **Typing never shows.** Only shortcuts (a key with ⌘ or ⌃) and keys such as Return, Tab, Esc, Delete and the arrows show. ⌥ with a letter types on a Mac (–, é, @), so it shows only in a Parallels Windows VM, as Alt.
- **A password field, or Terminal with Secure Keyboard Entry on:** macOS keeps the keys from every other app, so nothing shows. Turn off Terminal > Secure Keyboard Entry to show keystrokes there.
- **No pill anywhere, and the Keystrokes row names an app with secure keyboard entry on:** that app keeps the keys (some apps leave it on after their password field closes). Click into it and out of its password field, or quit it.
- **Not in screen.mov:** turn on Keystrokes > Include keystrokes in screen.mov, and set Keystrokes to While recording or Always, before Start.

## The take stopped by itself

- **The disk had 2 GB free.** TwinTake stops both files cleanly at that point.
- **"The Mac went to sleep, so the take stopped."** For example, you closed the lid on battery. The files are saved up to the sleep.

## Shortcuts do nothing

The shortcuts are fixed (see [guide.md](guide.md#shortcuts)). Open **Shortcuts** in the menu. If macOS or another app holds a shortcut, the error shows there in orange. Quit the other app or change its shortcut, then relaunch TwinTake.

## macOS asks for the permissions again

- **After each build:** the build is signed ad hoc. Add an Apple Development certificate. See [Signing](setup.md#signing-for-builders).
- **Screen recording still does not work after you allowed it:** quit and reopen TwinTake.

## Crashes and logs

**After a crash, a force quit or a power loss:**

- Both files play up to their last movie fragment. TwinTake writes one every 2 s, so you lose at most about 2 s.
- events.jsonl keeps every line written before the crash.
- At the next launch, TwinTake checks the take that was recording. It marks it `recovered` in session.json, adds the reason to `errors`, and logs a warning in events.jsonl. The menu says "Marked 1 interrupted session as recovered: …".
- A recovered session.json does not have the tracks and durations filled in.

**Logs:** TwinTake logs to the unified log, subsystem `com.lukebarousse.twintake`, category `session`.

- In the Console app, search for the subsystem `com.lukebarousse.twintake`.
- In Terminal:

  ```bash
  log stream --predicate 'subsystem == "com.lukebarousse.twintake"'
  log show --last 1h --info --predicate 'subsystem == "com.lukebarousse.twintake"'
  ```

**Crash reports:** macOS writes them to Console > Crash Reports (the files are in `~/Library/Logs/DiagnosticReports`).

**When you report a problem**, include the macOS version, the Mac model, what you did, and the take's session.json and events.jsonl. Check these files for personal paths and device names before you share them.
