# TwinTake

A native macOS menu-bar app that records your **camera** and your **screen** at the same time, into **separate files**, ready for Final Cut Pro.

- **Camera:** a capture card (for example an Elgato Cam Link 4K) at 4K 23.976, with the camera's own mic.
- **Screen:** a fixed 16:9 frame, a Mac mic as a backup and sync track, and system audio on its own track.
- **One folder per recording:** `camera.mov`, `screen.mov`, `session.json`, `events.jsonl` and `voice.jsonl` (when a mic was recorded). See [docs/SCHEMA.md](docs/SCHEMA.md).
- **Replay while recording:** watch what you just said, with the screen, while the take goes on. See [Replay](#replay).

Status: early development. Built for one creator's desk setup; support is not promised.

## Build

Requires macOS 15 or later and Swift 6 (Xcode or the Command Line Tools).

```bash
scripts/build-app.sh          # debug build -> build/TwinTake.app
swift test                    # unit tests
```

Sign in to Xcode with your Apple ID once (Xcode > Settings > Accounts). The build script then signs with your free "Apple Development" certificate, so macOS keeps the camera, mic and screen permissions between builds.

## Use

Open `build/TwinTake.app`. It lives in the menu bar (record icon), not the Dock.

1. Pick **Camera**, **Screen** or **Both**.
2. Under **Permissions**, allow Camera, Microphone, Screen Recording and Accessibility. Quit and reopen the app after you allow Screen Recording.
3. Check the **Signal** line under Camera, for example "4K · 3840×2160 · 23.976 fps". camera.mov records exactly what the camera sends, so there is no size or rate setting: you change it on the camera. An orange line means the camera sends less than 4K; the fix is under it ("Set the a6600 HDMI output to 4K 24p"). Change the camera's size or rate only while nothing records: a change during a take (also a rate change at the same size, such as 24p to 30p) turns the icon orange, because camera.mov keeps the grid it started with. Stop, then start again.
4. Under Screen, pick the **Display** and the **Frame**. The size in pixels shows next to the Frame picker. The **Rate** line shows the screen rate: 2× the camera rate (47.952 fps for 23.976), so a 23.976 timeline uses every other screen frame. It is not a setting. In Screen mode it follows the camera rate of the last take with the camera (47.952 until then).
5. Fix anything marked with a red icon. Red items block Start; orange items are warnings.
6. Click **Record** on the control bar (or **Start Recording** in the menu). The app snaps the front window into the frame, dims the rest of the display and starts both files at one shared time, half a second after the click, so they begin within one camera frame of each other.
7. Click **Stop** on the control bar (or press the shortcut). The session folder is in `~/Movies/TwinTake` unless you picked another folder.

While recording, an orange menu bar icon and a beep mean that something needs you: a file ended early, the camera sends no picture, or the camera mic warns (see [Mic meters, Mic check and warnings](#mic-meters-mic-check-and-warnings)). Open the menu to see what. Recording stops by itself when the disk has 2 GB free, so both files finish cleanly; preflight counts free space the same way (without purgeable space), so a Start that looks fine does not stop a minute later. It also stops when the Mac goes to sleep (for example, you close the lid on battery). If the recording folder's disk is not connected, or TwinTake cannot write there, Start is blocked.

The menu stays attached under the menu bar when its height changes (another mode, a disclosure arrow, a notice). It scrolls when it is taller than the display.

### Control bar

A small floating bar, like CleanShot X's recording controls, shows while TwinTake runs (idle and recording). It is never recorded and never takes the focus from your app. Left to right:

- **Record / Stop** with the elapsed time: the main Start and Stop. Idle it reads **Record**; then **Starting…** (click again to cancel the start), **Stop 12:34** in red while recording, and **Saving…**. It turns orange when something needs you: Start is blocked (the tooltip says why; a click checks once more, then beeps and says "Not ready: open the menu", and changes nothing else: the camera, the mics, a mic check and the replay stay as they are), a file has a problem, or the camera mic warns.
- **Pinned apps:** one button per app, with its icon and a short name. One click brings the app forward, waits until it is the front app, and snaps its front window into the frame, with the same rules as Snap: Parallels Desktop keeps its toolbar above the frame. The app's window on the frame's display comes first; a window on another display moves into the frame only when the app has none there. In Camera mode there is no frame, so the button only switches apps. An app that is not running opens ("Opening Dia…"), and its first window snaps. If macOS does not bring the app forward, its window does not move: the bar shows "Dia not in front", so the keyboard never stays with another app behind a snapped window. For a Parallels VM button, the window with the VM's name ("Windows 11") comes before the Control Center and other VMs. A click during **Starting…** switches the app at once and snaps its window when the take records, so the snap is logged like any snap during the take.
  - **+** pins the app you were in before the click (the bar does not take the focus, so that is the front app). Nothing is built in: click Dia, then **+**; click the Parallels VM window (the menu bar shows "Windows 11"), then **+**. That button finds the VM window that Parallels Desktop owns.
  - More than five apps go into the menu under the arrow at the end of the buttons.
  - Reorder or remove them in the menu under **Control Bar**, or right-click a button (Move Left, Move Right, Remove).
- **Replay** (⌃⌥⌘P), right of Flag: opens the replay window, or closes it. While recording it plays the take so far; idle, the last take. Lit while the window shows. See [Replay](#replay).
- **Flag** (⌃⌥⌘B): "something in the last few minutes was wrong". You often notice a mistake a minute or two later, so a flag points back: events.jsonl gets a `marker` with `kind` `flag` and `lookback_s` (see [docs/SCHEMA.md](docs/SCHEMA.md)). The take goes on. The bar shows "Flagged · last 3 min" for a moment. Set how far back under **Control Bar > Flag looks back** (default 3 min). Flag works only while recording.
- A thin vertical **Mac mic** meter, whenever the meters run (the camera window or Live preview is on, a take, a mic check). The camera window shows the camera mic along its bottom edge.

Drag the bar by any spot that is not a button. It remembers its place on each display and stays on screen when the displays change. Its first place is the middle of the strip above the bottom 16:9 frame on the recording display (above the Parallels toolbar strip while "Hide the Parallels toolbar" is on), else top-center under the menu bar. Right-click it for **Move to the Default Place** and **Hide Control Bar**. The switch next to **Control Bar** in the menu shows or hides it.

The bar and the camera window sit just above the dim around the frame, so they are never dimmed, and other apps' menu bar menus and popovers (for example a display utility's popover) open over them. TwinTake's own menu opens over them too. `sharingType = .none` and the screen recorder's own exclusion of TwinTake keep both out of screen.mov.

### Screen frame and options

- **Frame:** "16:9 frame" is 1504×846 pt (3,008×1,692 px) on a 14" MacBook Pro; "Whole display" fits a 16:9 monitor.
- **Frame position** (Screen > Options): **Bottom** puts the 16:9 frame flush with the bottom of the display, **Top** puts it under the menu bar. The default is Bottom on the built-in display and Top on other displays. The app remembers the choice for each display. On the 14" laptop, the bottom frame starts at y 136, so it leaves 136 pt minus the menu bar height free under the menu bar (103 pt with a 33 pt menu bar), for example for the Parallels toolbar.
- **Dock:** with the bottom frame, turn on "Automatically hide and show the Dock" (⌥⌘D). If a visible Dock covers the frame, or can move onto it from another display, an orange warning says so. A hidden Dock still slides in when the pointer touches the bottom edge, and screen.mov records it then.
- **Hot corners:** a hot corner at an edge the frame reaches (System Settings > Desktop & Dock > Hot Corners) runs when the pointer gets there, for example on the Windows taskbar in the bottom frame, and screen.mov records it (Quick Note's thumbnail, Mission Control). An orange warning names the corner. Turn it off, or set a key to hold for it.
- **Snap** (the button next to Show frame, or ⌃⌥⌘F) moves the front window on the frame's display into the frame. A pinned app's button on the control bar snaps that app's front window instead. The button names that window, for example **Snap: Windows 11 (Parallels)** or **Snap: Safari**, and updates while the menu is open. A window on another display never moves; with no window on the frame's display, the notice says so ("No window to snap on Built-in Retina Display"). If the named window cannot be moved (its app does not answer, or Accessibility does not list it), the snap fails with a notice that names it, and no other app's window moves.
- **Display refresh rate:** two frames must span a whole number of refreshes (within 0.5%). At 47.952 fps, 120 Hz (5 refreshes per 2 frames), 95.9 Hz and 47.95 Hz are fine. At 60 Hz, preflight asks you to set 120 Hz. ProMotion gets no advice unless its top rate fails the rule.
- **Options** (disclosure arrow under Screen):
  - **Record computer sound:** sound from videos and apps, on its own track (screen.mov A2).
  - **Snap the front window into the frame on Start.**
  - **Hide other windows:** records only the snapped app; menus it opens may be missing.
  - **Dim outside the frame.**
  - **Hide the Parallels toolbar** (on by default) and its **Toolbar offset**. See below.

### Parallels Desktop

With **Hide the Parallels toolbar** on, Snap places the Parallels Desktop window so its toolbar (the title and the icon strip) sits just above the frame, and only the Windows screen is in the frame. Parallels then sets the VM screen to the frame size (3008×1692 on the laptop).

- The toolbar needs room between the menu bar and the frame, so use the bottom frame. With the top frame the window does not move, and the menu offers **Move Frame to Bottom** (with the whole-display frame: **Use 16:9 Frame at Bottom**). That button moves the frame and snaps again.
- If a strip of the toolbar shows at the top of the recording, raise **Toolbar offset** (+ moves the window up). If the top of the Windows screen is cut off, lower it. Snap again after a change.
- With **Hide other windows** on, a Parallels window with its toolbar above the frame records the frame region instead (a window capture would include the toolbar).
- A Windows app in Coherence mode has no Parallels toolbar, so it fills the frame like any other app.

### Camera window

A small floating window shows your camera, so you can watch yourself while you talk. It is never recorded: the screen file shows what is under it.

1. Turn on **Camera window** under Camera, or press ⌃⌥⌘C. The arrow next to the switch shows its options: **Mirror**, **Keep the camera window on while recording** and **Live picture while recording**.
2. Drag the window to move it. Drag near its edge or a corner to resize it; it keeps the 16:9 shape.
3. Right-click it for **Mirror**, the sizes (Small, Medium, Large), **Mic Check**, **Reconnect Camera** and **Hide**. The close button shows when the pointer is over the window.
4. Other apps' menu bar menus and popovers open over the window (it sits just above the dim, near the floating window level).

- The picture is mirrored by default, like a webcam. camera.mov is never mirrored.
- Clicking the window does not take focus from your app, so ⌃⌥⌘F still snaps your app's window.
- The window stays on while recording, with a red dot and the elapsed time. To hide it at Start, turn off **Keep the camera window on while recording**. With that off, ⌃⌥⌘C does not show it during a take.
- While recording, the window shows the camera live: a small preview output stays in the camera session next to the full-size recording output. If a take ever drops camera frames, turn off **Live picture while recording**; the window then shows only the timer. The preview output is kept only when the window is on at Start: a window turned on during the take says "The camera window was off at Start, so this take has no live picture."
- Codec and bitrate changes (Recording Settings) never open the camera again; the next take uses them. Recording Settings (codec, bitrates, folder) can be changed only while nothing records.
- **Live preview** (the switch right above the preview picture in the menu) shows the camera in the menu while it is open.
- The window remembers its place and size on each display. It opens first on a display that does not hold the recording frame.
- The camera is open only while something shows it: the camera window, the open menu with **Live preview** on, or a take. Then it stays open between takes, so Start is quick. Between takes the camera session holds the picture and the camera audio, for the meters: macOS shows the green camera indicator and the orange microphone indicator. When nothing shows the camera any more (you hide the window, close the menu, or press Stop with the window off), the camera and the mics close about 1.5 s later, and both indicators go off. A quick close and reopen (the menu, or ⌃⌥⌘C twice) keeps the camera open. When the display sleeps, the screen locks or you switch to another user, the window shows nothing, so the camera and the mics close at once; they open again when you come back. An open camera also uses more power. Without microphone access, the preview opens without the meters, and nothing asks for the permission.
- If the camera sends no picture, the window opens the camera again a few times, then waits with "No picture from the camera". Open the menu, or hide and show the window, to try again.
- Whenever the camera mic is metered (before recording while the window shows, during a mic check, while recording), a bar along the bottom edge of the picture shows the camera mic level: green, yellow above -12 dBFS, red above -3 dBFS, and a tick at the peak of the last 1.5 s. Warnings show as a banner above it (see below).

If you plug the capture card into another USB port, macOS gives it a new device ID. TwinTake finds it again by its name and model (the model without its USB product id, which changes when the Cam Link comes back on its USB 2 lane) and says so ("Cam Link 4K moved to a new USB port; reconnected"). It never switches to a device with the same name that it saw connected next to yours (a second Cam Link), and it rematches an audio input only when it is a USB device of the same maker and product (never a Bluetooth or built-in input). If two new devices have that name, pick one in the menu.

| Shortcut | Action |
|---|---|
| ⌃⌥⌘R | Start or stop recording |
| ⌃⌥⌘F | Snap the front window into the frame |
| ⌃⌥⌘B | Flag: something in the last few minutes was wrong (a `flag` marker with `lookback_s`) |
| ⌃⌥⌘C | Show or hide the camera window |
| ⌃⌥⌘P | Show or hide the replay window |

### Replay

Review what you just said, with the screen, while you still record. Click **Replay** on the control bar, press ⌃⌥⌘P, or click **Replay** next to Flag in the menu. Idle, the same button replays the last take (also next to its Saved line).

- **Picture:** screen.mov fills the window and camera.mov sits in its bottom-right corner, like the camera window over the screen. A Camera or Screen take shows its one picture. Click the picture to play or pause.
- **Timeline:** the whole take so far. Light green is speech, orange marks are flags and the stretches they point at. Drag it to scrub: while you drag, the picture shows the nearest keyframe before that point; when you let go, it shows the exact frame.
- **Where it opens:** at the last 60 s of the take, playing. **Live** jumps to the newest part that can be played: about 3 s behind the recording, because the files get a movie fragment every 2 s. The line next to the time says how far behind live the picture is.
- **Controls:** play / pause, back and forward 10 s, speed 1x, 1.5x, 2x. At a faster speed it drops to 1x when it catches up with live.
- **Skip silence:** jumps over pauses longer than 1 s and keeps 0.25 s around speech, so words are never cut. It follows the camera mic (the Mac mic when the camera mic is silent or there is none). Where the camera mic heard no voice for 2 s around speech the Mac mic heard (the Rode unplugged and the a6600 silent for a few minutes), it plays that speech too. The voice timeline is collected during the take from the same 50 ms blocks as the mic warning; it is saved at Stop as voice.jsonl, so a saved take skips its silence too. While recording, once everything said so far has played (you are likely silent, watching the replay), it waits and plays on when there is more speech; **Live** still jumps to live.
- **Flags only:** plays only what each flag points at: its look-back (Control Bar > Flag looks back) and 10 s after it. The arrows go to the previous and next flag. When two flags' stretches overlap, the next arrow goes from the first look-back to where the first flag was pressed: what comes after that press is new to the second flag. With both switches on, it plays the speech inside the flagged stretches.
- **Sound:** off by default: the speakers would be in the Rode and the MacBook mic. Turn it on with headphones (the window says so). It plays the dialogue (the camera mic, else the Mac mic) and the computer sound, never both mics. Replay's sound is never in screen.mov's computer sound track: the screen recorder leaves TwinTake's own audio out. While it plays with Sound on, the camera mic warning does not listen (the speakers' sound is not your voice): it listens again 0.5 s after the replay pauses or ends, Sound goes off, or the window closes. A mic check plays the replay muted ("Muted while the mic check runs."), so the check hears only you; Sound comes back after it.
- **For the editor:** while recording, events.jsonl gets `replay_start` when the window opens, `replay_end` when it closes (or at Stop), and `replay_sound` when Sound changes, so the editor can cut the stretch you spent in the replay (see [docs/SCHEMA.md](docs/SCHEMA.md)).
- **The recording comes first:** the replay only reads camera.mov and screen.mov. It never touches a writer or the capture, its work runs below the recorders' priority, and its pictures are decoded in hardware. It decodes as little as it can: one keyframe for each step of a drag, and after a jump it skips the frames before the target that no other frame needs. If a recorder logs dropped frames while the replay plays, the replay pauses and says so ("Paused: camera.mov dropped frames. Play goes on."). Hidden (the display asleep or the screen locked), it decodes nothing; closed, it lets go of everything. At Stop it lets go of the files while they are finished, then opens the saved take again where it was.
- **A file that ends early:** if camera.mov ends during the take (the camera was disconnected), the replay goes on with screen.mov, and the camera corner goes black past the camera's end. The same goes the other way round. A saved take plays to the end of its longer file.
- **The window** is never in screen.mov, never takes the focus from the app you record (its buttons work without making TwinTake active), sits at the camera window's level, and remembers its size and place on each display. Closing it never stops the recording. The controls keep 12 pt from the window's edges and 8 pt between buttons; the close button (X) sits 12 pt in from the left edge.

### Mic meters, Mic check and warnings

The camera audio (camera.mov A1) is the dialogue track. With an external mic (a Rode) in the a6600's mic jack, the camera records the Rode. When the Rode is unplugged, the a6600 may switch to its built-in mic without a sound, or send silence: in take 2026-10-13_205644 its audio stayed flat at -69 dBFS until the Rode went back in. TwinTake listens for both.

- **Meters:** before recording, whenever the camera preview is on (the camera window shows, or the menu shows its Live preview), two meters show under Start Recording: **Camera mic** (the Cam Link HDMI audio, so the Rode through the a6600) and **Mac mic**. While recording, three meters show under Stop: **Camera mic** (camera.mov A1), **Mac mic** (screen.mov A1) and **Computer sound** (screen.mov A2). Computer sound has a meter only while recording, because it needs the screen stream. The bar is green, yellow above -12 dBFS and red above -3 dBFS. The tick is the peak of the last 1.5 s, and the number next to the bar is that peak. **CLIP** means samples at or above -1 dBFS: while recording, at any time since Start; before recording, in the last 1.5 s (so the clap for sync does not keep CLIP on after Stop). The meters update about 20 times a second, only while the menu or the camera window is open.
- **Mic Check:** open **Recording Settings > Mic check** and click **Mic Check** (or right-click the camera window > Mic Check), then talk for 10 s. The meters before recording make it rarely needed: they run whenever the camera preview is on. A check started from the camera window opens Recording Settings, where its countdown and result show. While the camera preview is on, the check listens to the live meters and opens no mic. Otherwise it opens the camera audio and the Mac mic only for those 10 s: the orange microphone indicator shows during the check and goes off after it. The camera picture is not touched. The result is, for example, "Rode detected", "Rode not detected — the camera is using its built-in mic", "The camera mic isn't picking up your voice", "No voice heard" or "Not sure which mic the camera uses" (talk longer, or calibrate). It stays in the menu for 5 minutes at most. A Start that goes on clears it and cancels a running check; a Start that is blocked leaves both.
- **Warnings, before recording and at the start of a take:** if the camera records with its built-in mic, a banner in the menu and in the camera window says "Rode not detected — the camera is using its built-in mic." If the Rode is plugged in but switched off, or the camera sends no sound, it says "The camera mic isn't picking up your voice." The check is for before recording and the very beginning of a take; you do not unplug the Rode once a take runs.
  - **Before recording**, the check runs the whole time the camera mic is metered (the camera preview is on). The banner shows, and the menu bar icon turns orange, without a beep.
  - **In a take**, Start begins the check again. Once your speech confirms the Rode (about 6 s of clear voice, so within about 10 to 15 s of talking), the check is off for the rest of the take: the line under the meters says "Rode confirmed · L/R 0.98…" and "The mic check is off for the rest of this take.", events.jsonl gets one `mic_confirmed`, and no mic banner, beep or orange icon comes in that take, however long you pause. Until then, a warning turns the menu bar icon orange with one beep; it does not beep again until the warning has cleared. A take where you only start to talk after 3 minutes is checked until then.
  - **What counts:** only clear voice. A block counts for the Rode rule when the camera mic is 20 dB above its noise floor and above -50 dBFS; faint sounds (room noise, typing, the replay's speakers, about -55 dBFS) do not, so pauses never warn. Neither do sounds only the MacBook hears (typing on its keyboard) or only the camera hears (the click of a plug in the a6600's mic jack), nor anything while the replay plays with Sound on. The silent-mic warning needs about 8 s of clear voice on the Mac mic, so about 15 s of talking.
  - In Camera mode TwinTake keeps the Mac mic open during the take (it meters it, it does not record it), so the silent-mic warning works there too. session.json records the mic of each take (`mic_source`, with `confirmed` and `confirmed_at_s`), and the Saved line says when camera.mov used the built-in mic.
- **Calibrate mic warning:** the default rule is the camera's L/R correlation over clear voice: the Rode sends the same signal on both channels (near 1: 0.97 to 0.99 on speech), the built-in stereo mic does not (below 0.88). Through the Cam Link the right channel arrives one sample after the left, so faint broadband sound reads lower (about 0.85) even from the Rode: that is why only clear voice counts. If the warning misses the built-in mic, calibrate it: open **Recording Settings > Mic warning**, click **Calibrate Mic Warning…**, record sample 1 with the Rode plugged in (talk for 10 s), record sample 2 with the Rode unplugged (talk for 10 s), then click **Save Calibration**. The thresholds show under Mic warning; **Reset** goes back to the default rule. Swapped samples (sample 1 without the Rode) are refused, and the flow starts over. A calibration saved before the clear-voice rule (calibration version 2, made from every voiced block) no longer loads: the default rule applies until you calibrate again. While the camera preview is on, each sample listens to the live meters. If a sample says "The camera sent no sound", the Mac mic heard you but the camera audio stayed silent: without the Rode, the a6600 recorded silence instead of its built-in mic (take 2026-10-13_205644). Pull the plug out of the a6600's MIC jack itself, wait 30 s, and record the sample again. If the camera stays silent, you need no calibration: the warning "The camera mic isn't picking up your voice" covers that case. A calibration that tells the mics apart by level only compares the camera mic with the Mac mic, so it works only while TwinTake meters the Mac mic (not with Screen > Mic set to None). Each sample counts only voice that the Mac mic hears too; if a sample says "Only … s of voice that the Mac mic heard too", talk a little louder.
- **Cam Link health:** if the Cam Link comes back on its USB 2 lane after an HDMI change (it still offers 4K but sends empty frames), a red banner says "Cam Link is connected at USB 2 speed." and Start is blocked: unplug it and plug it back in. This banner comes first, and Reconnect is not offered with it. A Cam Link on USB 2 is flagged with any signal (1080p too, since it sends uncompressed video); another capture card only with 4K. If the frames hold no picture (a solid green preview), the picture shows "No picture" instead of the green box and a red banner offers **Reconnect Camera** (only while nothing records); Start is blocked while they last. If the camera does not open again within 20 s, Reconnect works again and the notice says to replug. A camera that does not answer preflight within 5 s blocks Start too: "The camera does not answer. Unplug it and plug it back in." TwinTake also reopens the camera once by itself. The Cam Link sends about 12 all-zero frames each time its stream starts: frames in the first second after each open do not count, so opening the preview never makes it reopen. One flat color everywhere (for example a lens cap) shows the same banner in orange, as a warning only. A replug fixes the USB 2 case.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for code adapted from other MIT projects.
