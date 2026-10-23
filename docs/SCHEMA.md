# Session folder format (schema 1.6)

Every recording is one folder. Editing tools read it; they never change the raw files.

```
~/Movies/TwinTake/2026-10-12_174000/
├── camera.mov      camera modes only
├── screen.mov      screen modes only
├── session.json    what was recorded, with which devices and formats
├── events.jsonl    timeline of events (markers, snaps, errors, replays, keystrokes), one JSON object per line
├── voice.jsonl     when the speaker talks (1.4), written at Stop when a mic was recorded
└── derived/        not created by the recorder; reserved for tools (transcripts, FCPXML)
```

## Files

| File | Video | Audio track 1 | Audio track 2 |
|---|---|---|---|
| `camera.mov` | Capture card, e.g. 3840x2160 at 24000/1001, constant frame rate | Camera mic (HDMI audio from the capture card) | — |
| `screen.mov` | 16:9 frame, e.g. 3008x1692 at 48000/1001, constant frame rate | Mac mic (backup and sync reference) | System audio |

- Audio is 48 kHz 24-bit linear PCM. Tracks are never mixed together.
- Frame rates are exact rationals. 23.976 is `24000/1001`, never `24`.
- Both video tracks are constant frame rate on an exact grid: the track timescale is the rate's numerator (24000 for 23.976, 48000 for 47.952) and every frame lasts `den` ticks (1001). The grid follows real time (the host clock): a slot no frame reached repeats the previous picture, and a frame that reaches a slot that already has one is skipped. camera.mov corrects for a capture card that stamps a nominal frame interval (the Cam Link 4K stamps 1251/30000 s per frame for a 23.976 signal), so its picture stays with its audio over long takes.
- Every audio track is trimmed and padded (with silence) onto its file's video timeline: it starts at the video's first frame and ends with its last.
- The camera size and rate follow the camera's signal (its largest format; 23.98 from the Cam Link is recorded as 24000/1001). The screen rate is 2x the camera rate up to 30 fps (47.952 for 23.976), so a 23.976 timeline uses every other screen frame.
- Both files get a movie fragment every 2 s (the first after 1 s), so a crash keeps everything up to the last fragment.
- Both files start together: the app gives both recorders one start time a little in the future, and each file begins at its first frame at or after it, so they begin within one camera frame of each other. `first_pts_host_ns` says exactly where each one begins.

## session.json

Keys are snake_case. Main fields:

| Field | Meaning |
|---|---|
| `schema_version` | `"1.6"`. Changes inside 1.x only add fields. 1.1 added the `slots_*` and `measured_*` track fields, `screen.frame_anchor`, and `snapped_window.placement`, `toolbar_pt` and `window_frame_pt`; camera.mov became constant frame rate. 1.2 added `mic_source` on camera.mov's mic track and the events `mic_detector`, `usb_link` and `empty_frames`. 1.3 added the `marker` kind `flag` with `lookback_s` (it replaces `good` and `retake`), and the `window_snap` values `picked_by` `pinned_app` and `failure` `no_app_window`. 1.4 added voice.jsonl and the events `replay_start`, `replay_end` and `replay_sound`; session.json has no new field. 1.5 added `mic_source.confirmed` and `confirmed_at_s` and the event `mic_confirmed`: a take checks the camera mic only until the external mic is confirmed, and only clear voice counts as evidence (see the mic source fields). 1.6 added the event `keystroke` and the `session_start` fields `keystrokes` and `keystrokes_in_screen`; screen.mov can show the keystroke pill; session.json has no new field. |
| `status` | `recording` while recording; `complete` after Stop; `failed` after Stop or a failed Start when `errors[]` is not empty (the files are kept); `recovered` if the app found it after a crash. A Start cancelled before the files began leaves no folder. A failed Start that wrote no movie keeps its folder (`failed`, with the reason in `errors[]`), but the app does not offer it as the last take. |
| `mode` | `camera`, `screen` or `both`. |
| `recorder` | `name`, `version`, `git_sha`. |
| `host` | `model`, `macos_version`. |
| `tracks[]` | One entry per track: `file`, `track_index`, `role` (`camera_video`, `screen_video`, `mic`, `system_audio`), `dialogue` (true on at most one track: the camera mic, else the screen mic; none when the session has no mic track), `device` (`name`, `uid`, `negotiated_format`), `codec`, `width`, `height`, `frame_rate` (`num`, `den`), `constant_frame_rate`, `sample_rate`, `channels`, `first_pts_host_ns`, `first_pts_source`, `duration_s`, `dropped_frames`, and for video `slots_repeated`, `slots_skipped`; for camera video also `measured_pts_fps`, `measured_arrival_fps`; for camera.mov's mic track `mic_source`. See the track fields below. |
| `screen` | `capture` (`region` or `window`), `display_id`, `display_name`, `scale`, `preset`, `frame_rect_pt` (display-local, top-left origin), `frame_anchor` (`top`: under the menu bar; `bottom`: flush with the display's bottom edge; absent for the whole-display preset), `output_px`, `snapped_window`. See the snapped window fields below. A `window` capture records only the snapped window, scaled to fit; with the keystroke pill in screen.mov (1.6, `keystrokes_in_screen` `on`) it records the frame region with only that window and the pill in it. |
| `camera` | `hdmi_format`, `effects_active` (macOS video effects that were on). |
| `sync` | `reference: "host_clock"`: every `*_host_ns` value is on one clock. `check`: `"shared_voice"` when camera.mov and screen.mov both have a mic track, so audio sync works too; else `"none"`. |
| `started_at_host_ns`, `stopped_at_host_ns`, `duration_s`, `errors[]` | Session timing and problems. |

To line files up: offset of a track = `first_pts_host_ns` − the smallest `first_pts_host_ns` in the session.

### Snapped window fields

`screen.snapped_window` is the window the app snapped into the frame (at Start, or the last snap during the take that replaced it).

| Field | Meaning |
|---|---|
| `app_name`, `bundle_id`, `title`, `window_id` | The window. A window capture (`capture: window`) records `window_id`. |
| `placement` | `fill`: the whole window covers the frame. `toolbar_above`: the window's content area covers the frame and its toolbar sits just above it, outside the recording (Parallels Desktop with "Hide the Parallels toolbar" on). |
| `requested_pt` | The frame size the app asked for. |
| `achieved_pt` | The size of the recorded part of the window: the whole window for `fill`, the content area for `toolbar_above`. Compare it with `requested_pt`. |
| `achieved_frame_pt` | Where the recorded part landed, display-local points, like `frame_rect_pt`. |
| `toolbar_pt` | `toolbar_above` only: the strip above the frame, in points (the detected toolbar height plus the user's offset). |
| `window_frame_pt` | `toolbar_above` only: the whole window, toolbar included, display-local points. |

### Track fields

| Field | Meaning |
|---|---|
| `first_pts_host_ns` | Host time of the track's first sample in the file: file time 0. Never the time of a frame or buffer from before the file began (the camera runs from prepare on). Every track of one file has the same value: its audio is trimmed and padded to start with its first frame. |
| `first_pts_source` | `sample`: from the frame's own timestamp. (`callback`, approximate, is no longer written.) |
| `constant_frame_rate` | `true` for both video tracks. |
| `dropped_frames` | Camera video: slots that repeat a picture because no frame came for them, plus frames that came too late for their slot. Screen video: frames that came too late (a static screen repeats its picture on purpose; that is `slots_repeated`, not a drop). |
| `slots_repeated` | Video: written slots that repeat the previous picture. |
| `slots_skipped` | Video: frames that arrived but took no slot. Camera: the camera sent more frames than the grid has slots. Screen: a newer frame for the same slot replaced it (normal when the display refreshes faster than the grid). |
| `measured_pts_fps` | Camera video: the rate the frame timestamps run at (least squares over the take), e.g. `23.9808` for the Cam Link's 1251/30000 s stamps. |
| `measured_arrival_fps` | Camera video: the rate the frames really arrived at on the host clock, e.g. `23.976`. camera.mov follows this one. |
| `mic_source` | camera.mov's mic track only (1.2): which mic the camera recorded with, as the camera mic detector heard it during the take. See the mic source fields below. Missing when no camera audio arrived. |

### Mic source fields

The camera mic detector compares the camera audio (camera.mov A1) with the Mac mic (screen.mov A1), over voiced 50 ms blocks only: a block is voiced when its level is 10 dB above that mic's noise floor (the lowest block level of the last 3 s) and above -65 dBFS. Pauses and silence add nothing. An external mono mic in the camera's mic jack sends the same signal on both channels (dual mono: L/R correlation near 1, 0.966 to 0.992 per 6 s of voice in take 2026-10-13_205644); the camera's built-in stereo mic does not. Without a calibration the rule is: mean correlation below 0.88 over the last 6 s of evidence means the built-in mic. The level against the Mac mic is a rule only with a calibration. A calibration (one mic check with the external mic plugged in, one with it unplugged) sets the correlation threshold, and a threshold for the level against the Mac mic, between the two samples.

- **Evidence gate (1.5):** the rules count a voiced camera block only when it is also 20 dB above the camera's noise floor and above -50 dBFS (and, while the Mac mic runs, the Mac mic hears it too). Through the Cam Link the camera's right channel is its left channel one sample (21 µs) later, so the L/R correlation of the Rode depends on the sound: near 1 for voiced speech, about 0.85 for faint broadband sound (room noise, typing, speakers). In take 2026-10-14_093840 (the Rode in all the time) such sounds, about -55 dBFS and 13 dB above the floor, gave 6 s means of 0.857 and 0.853 and two false built-in mic warnings. The gate keeps about 90% of the speech blocks and rejects 119 and 120 of the 120 blocks behind those two warnings. Before 1.5 every voiced block counted.
- **Confirmation (1.5):** a take checks only until its speech confirms the external mic: a full 6 s window of gated evidence past the far edge of the band (correlation 0.89 or more with the default rule) for 1 s, with the verdict `external_mic`. Then the take logs one `mic_confirmed`, and for the rest of it the verdict, the silent-mic warning, the banners and the beep stop. Before recording (the idle meters) and in a mic check the rules never stop. A take that is never confirmed is checked to its end.
- **Paused evidence (1.5):** while the replay window plays with Sound on (see `replay_sound`), the speakers' sound can reach both mics: no block counts then, nor for the next 0.5 s (10 blocks), also not for the silent-mic warning. A paused, ended or hidden replay pauses nothing. A mic check plays the replay muted, so it never pauses a check.

| Field | Meaning |
|---|---|
| `verdict` | At Stop: `external_mic`, `built_in_mic` or `unknown` (less than 6 s of gated voice, or mono camera audio without a calibration). After a confirmation it stays `external_mic`. |
| `verdicts_seen` | Every verdict the take reached, in order (`unknown` left out), e.g. `["external_mic", "built_in_mic"]` when the mic was unplugged during the take. |
| `confirmed` | 1.5: `true` when the take confirmed the external mic (the checks then stopped), `false` when it never did. Missing before 1.5. |
| `confirmed_at_s` | 1.5: take time of the confirmation, in seconds since `started_at_host_ns` (one decimal). Missing when `confirmed` is not `true`. |
| `camera_mic_silent` | `true` when the warning "The camera mic isn't picking up your voice" was on at some point (before the confirmation): the Mac mic heard clear voice (15 dB above its floor, for at least 150 ms in a row, so keystrokes do not count) for 8 s while the camera mic stayed within 6 dB of its own floor (±200 ms allowed for the camera's lag). |
| `mean_correlation` | Mean L/R correlation of the camera audio over the take's gated camera blocks (the whole take, also after the confirmation; not while the replay's Sound was on). While the Mac mic is metered, only blocks that both mics hear count, so a click in the camera's mic jack does not. Missing for mono camera audio. |
| `level_vs_screen_mic_db` | Mean camera mic level minus Mac mic level, in dB, over the gated blocks where both mics hear voice (a sound only the MacBook hears, such as its keyboard, does not count). Missing without a Mac mic. In Camera mode the app meters the Mac mic for the detector without recording it. |
| `voiced_s`, `screen_mic_voiced_s` | Voiced time of the camera mic and of the Mac mic, in seconds. In Camera mode, `screen_mic_voiced_s` comes from the metered (not recorded) Mac mic. |
| `calibrated` | `true` when a saved calibration set the rules. |
| `correlation_threshold` | The correlation threshold used (`0.88` without a calibration; `0.95` in recordings made before that change). Missing when no correlation rule applied. |

## events.jsonl

One object per line: `t_host_ns`, `wall` (ISO 8601), `type`, optional `data`.
Types: `session_start`, `session_stop`, `track_start`, `track_stop`, `marker` (`data.kind`: `flag`; recordings before 1.3 have `retake` and `good`; `chapter` and `note` are reserved), `window_snap`, `window_move`, `dropped_frames`, `device_lost`, `camera_graph`, `mic_detector`, `mic_confirmed`, `usb_link`, `empty_frames`, `replay_start`, `replay_end`, `replay_sound`, `keystroke`, `warning`, `error`.

- `session_start` is at the scheduled start time (`t_host_ns` = session.json `started_at_host_ns`), about 0.5 s after the recorders were ready, so its line can come before `track_start` lines with an earlier time. `data`: `mode`, `folder`, `camera_format` (e.g. `3840x2160 420v 23.976`), `camera_signal` (e.g. `3840x2160 · 23.976 fps`), `screen_output_px`, `screen_frame_rate` (`48000/1001`: 2x the camera rate, not a setting), `frame_anchor` (`top`, `bottom`, or `none` for the whole display), `scheduled_start_margin_ms` (`500`), in camera modes `camera_window`, and (1.6) `keystrokes` (`off`, `while_recording` or `always`: the Keystrokes setting at Start) and in screen modes `keystrokes_in_screen` (`on` when the keystroke pill is in screen.mov, else `off`; always `off` when `keystrokes` is `off`).
- `marker` with `kind` `flag` (the control bar's Flag button or ⌃⌥⌘B, while recording) means "something in the last few minutes was wrong": the speaker noticed a mistake after it happened, and the take went on. `data`: `kind` `flag`, `elapsed_s` (seconds since the files began, i.e. since session.json `started_at_host_ns`, the `session_start` time; one decimal, e.g. `754.2`, so it is the press's time in camera.mov and screen.mov) and `lookback_s` (the "Flag looks back" setting, `180` by default; whole seconds). The mistake is somewhere in [`elapsed_s` − `lookback_s`, `elapsed_s`] (clamp the start at 0); `t_host_ns` is the press. Legacy markers (`good`, `retake`, before 1.3) have `kind` and `elapsed_s` only. `session_stop` has `markers`: how many markers the take has.
- `replay_start`, `replay_end` and `replay_sound` (1.4) are the replay window during the take: the speaker reviewed what was recorded instead of talking to the camera, so an editor cuts the take from each `replay_start` to its `replay_end`. Each has `elapsed_s` (take time like a flag's: seconds since `started_at_host_ns`, one decimal) and `t_host_ns` is the moment itself.
  - `replay_start`: the window opened during the take. `position_s` (where the replay opened, in take time: about the last 60 s), `sound` (`on`/`off`), `skip_silence` and `flags_only` (`on`/`off`).
  - `replay_end`: the window closed (`reason` `closed`), or the take stopped with it open (`reason` `stop`, at the Stop press: it comes before the `track_stop` lines and `session_stop`). `open_s` (how long it was open) and `sound_on_s` (how long of that its Sound was on: its sound may be in the camera mic and the Mac mic then, never in screen.mov's system audio, which leaves TwinTake's own audio out).
  - `replay_sound`: the Sound switch changed while recording. `state` (`on`/`off`).
  - A replay opened while nothing records (the last take) logs nothing: a saved take is never written to.
- `keystroke` (1.6) is one keystroke the on-screen pill showed during the take: a shortcut (a key with ⌘, ⌃ or ⌥, with or without ⇧) or a named key (Return, Enter, Tab, Esc, Delete, Forward Delete, the arrows, Page Up, Page Down, Home, End, F1 to F20) alone or with ⇧. Typed text never shows and is never logged: no plain character, no ⇧ with a character, no Space alone, no ⌥ or ⌥⇧ with a character or Space outside a Parallels Windows VM (on a Mac that types –, é or @; in the VM ⌥ is Alt and shows), nothing while secure keyboard entry is on (a password field), and none of TwinTake's own hotkeys. Modifiers held without a key and a held key's auto-repeats show but are not logged. `data`: `label` (the text the pill showed, without the count, e.g. `Ctrl+Shift+P` with Windows names or `⇧⌘P` with Mac symbols), `mac_label` (the same keys in Mac symbols, modifiers in the order ⌃⌥⇧⌘, e.g. `⇧⌘P`, `⌥⌘7`, `⌘ Return`, `Esc`), `repeat` (`1`, `2`, `3` …: presses of the same keys in a row while the pill showed; the pill reads `⌘Z ×3`) and `elapsed_s` (take time, like a flag's). `t_host_ns` is the press. A character key is named by the keyboard layout in use (`Z` for the key left of `U` on a German layout).
- `window_snap` has `success`, `requested`, `failure`, `app`, `bundle_id`, `title`, `window_id`, `previous`, `achieved`, `ax_error` (frames are `x,y,w,h` in global points), and `target` (e.g. `Windows 11 (Parallels)`), `display`, `picked_by` and `candidates`. `picked_by`: `front` (the front window on the frame's display), `recent_app` (the window of the app activated last), or `pinned_app` (a control bar app button: that app's front window, from another display only when it has none on the frame's display; for a Parallels VM's Dock helper, the Parallels Desktop window titled with the VM's name comes first, then the app's other Parallels windows). `failure` `no_app_window`: the pinned app has no window. A snap with `placement` `toolbar_above` (Parallels Desktop) adds `profile` (`parallels`), `toolbar_pt`, `toolbar_source` (`content_element`, `toolbar_element`, `title_bar_buttons`, `fallback` or `no_title_bar`), `toolbar_fine_tune_pt`, `window_target` (the window frame asked for: the frame plus the strip above it), `content` (the content area read back) and, for `failure` `toolbar_no_room` (the toolbar does not fit under the menu bar; the window did not move), `move_down_pt`.
- `window_move` has `fills_frame`: for a `toolbar_above` window, true while its content area covers the frame and its toolbar stays above it.

- `track_start` of the camera video (`role: camera_video`) has `data.preview`: `on` when the small 640x360 preview output stayed in the camera session while camera.mov recorded (the camera window was live), else `off`. Also `first_pts_host_ns`, `first_pts_source`, `format`, `codec`, `device`, `sync_clock`, `clock`, `scheduled_start_host_ns` (the shared start time), `start_lag_ms` (first frame − scheduled start, under one frame when on time), `warmup_ms` (how long the writer took to get ready), `frames_before_start` (camera frames since prepare that are not in the file), `first_frame_arrival_lag_ms` (arrival − the camera's timestamp, drift included), `corrected_arrival_lag_ms` (arrival − the corrected time: the capture latency, normally under 100 ms), `clock_correction_ms` (real time − the camera's timestamps, since the camera opened or its format was last set again; the preview counts, so a take after the camera window ran for 10 minutes starts at about 120 ms with the Cam Link), `frame_size` and `pixel_format` (of the frames the writer got, e.g. `3840x2160` `420v`).
- `track_start` of the screen video has `scheduled_start_host_ns` and `start_lag_ms` too.
- `track_stop` of the camera video has `slots_written`, `frames_written`, `slots_repeated`, `slots_skipped`, `late_frames`, `writer_busy_frames` (new frames written as a repeat because the encoder was behind), `other_size_frames` (only when the camera changed its signal size mid-take: frames not written), `dropped_frames`, `measured_pts_fps`, `measured_arrival_fps`, `clock_correction_ms`, `frames_before_start`, `clock`, `first_pts_host_ns`, `duration_s` and `playable`. The camera mic's `track_stop` has `gap_silence_ms`, `overlap_trim_ms` and `dropped_buffers`, like the screen audio tracks, and `mic_source` (the verdict, as in session.json) and `camera_mic_silent`.
- `mic_detector` means the camera mic detector changed its verdict or its silent-mic warning during the take, before the external mic was confirmed (none come after `mic_confirmed`). `data`: `verdict` and `previous` (`external_mic`, `built_in_mic`, `unknown`), `camera_mic_silent` (`true`/`false`), `correlation` (mean L/R correlation over the last 6 s of gated voice), `level_vs_screen_mic_db`, `voiced_s` (gated voice in the verdict window, up to 6), `calibrated`, `correlation_threshold`, and `message` when the app shows one ("The camera is recording with its built-in mic. …" or "The camera mic isn't picking up your voice. …"). The verdict changes only after the evidence stays past the far edge of a band around the threshold (±0.01 without a calibration) for 1 s of voice, so it does not flicker. The detector starts over at each Start.
- `mic_confirmed` (1.5): the take's speech confirmed the external mic, so the mic rules stop for the rest of the take (see the mic source fields). At most one per take; when the confirmation also changes the verdict, a `mic_detector` line comes right before it. `data`: `verdict` (`external_mic`), `correlation`, `level_vs_screen_mic_db`, `voiced_s` (`6.0`), `calibrated`, `correlation_threshold` and `elapsed_s` (take time of the confirming block, like a flag's).
- `usb_link` is logged at Start for a USB camera: `device`, `vendor_id` and `product_id` (hex, e.g. `0x0fd9`, `0x0066`), `location_id`, `speed_mbps` (e.g. `5000`), `usb` (`3`, `2` or `1`), `speed_code` (IORegistry `USBSpeed`: 3 high speed, 4 super speed 5 Gb/s), `label` (`USB 3 · 5 Gb/s`), `product`, and `slow_for_signal` (`true` when a capture card runs its signal under 5 Gb/s: an Elgato device such as the Cam Link with any signal, since it sends uncompressed video; another capture card with a 4K signal). That case also logs a `warning` with `data.source: camera`: "Cam Link is connected at USB 2 speed. Unplug it and plug it back in — 4K needs USB 3." ("1080p needs USB 3." for a 1080p signal). (The Cam Link 4K on its USB 2 lane reports product id `0x0067` and still offers 3840x2160, but sends empty frames.) Preflight blocks Start in that case (`camera.usb2`), so a take has it only when the link or the signal changed right before Start.
- `empty_frames` means the camera's frames arrive but hold no picture, during the take: `data.state` `start` (with `pattern`: `zero` for all-zero 420v planes, a solid green picture; `constant` for one flat value everywhere, `frames`, and `message` "No picture: the Cam Link is sending empty frames.") or `end` (with `frames`: empty frames in the episode). Also `pipeline` (`recording`, or `preview` for the small preview output) and `device`. An episode starts after 12 empty frames in a row (0.5 s at 23.976) and ends after 3 frames with a picture. Empty frames in the first second of each pipeline (from its first frame, and again after the camera's format was set again) do not count: the Cam Link sends about 12 all-zero frames each time its stream starts. While it lasts, the app shows the camera file as having a problem.
- A `warning` with `data.source: camera` and `data.measured_pts_fps`, `data.measured_arrival_fps`, `data.difference_percent` means the camera's timestamps and its real frame arrivals differ by more than 0.01% over a take of 30 s or more (a capture card that stamps a nominal interval). camera.mov followed the arrivals.
- A `warning` with `data.source: camera` and `data.corrected_arrival_lag_ms` means the first camera frame arrived more than 150 ms after its corrected time: the clock correction is off or the capture is slow. Frames later than 500 ms are dropped (`late_frames`).
- A `warning` "Audio gap filled with silence." has `track`, `gap_ms` (this gap) and `gaps` (gaps over 50 ms since the last such warning, this one included). At most one every 2 s per track.
- A `warning` "The audio clock changed during recording" means the track's sample clock changed mid-file; later audio is mapped with the new clock.
- A `warning` with `data.scheduled_start_host_ns` and a `message` "got ready ... after the scheduled start" means that recorder was not ready in time; its file begins at its next frame (see `start_lag_ms`).
- `dropped_frames` for camera.mov has `file`, `track`, `count` (since the last one) and `total`, at most every 2 s.
- `session_start` in camera modes has `data.camera_window`: `on` when the camera window stayed on for the take.
- `camera_graph` means the camera session changed what it holds. `data.from`: `closed`, `preview` or `recording`; `data.to`: `preview` or `recording`. The preview graph has the camera picture and the small preview output, and with the idle meters also the camera audio input and the camera mic meter (an audio output that only meters, no file); the recording graph has the camera audio input and the recording outputs (full-size video and the camera audio, written by AVAssetWriter), never the idle meter. From the metered preview, Start keeps the camera audio input and adds only the recording outputs. Also `data.ms` (how long the change took), `data.audio_input`, `data.audio_meter` and `data.preview_output` (`on` or `off`; `audio_meter` added in 1.2 recordings from this change on), `data.format` (what the camera runs after the change), `data.format_reset` (`true` when the change reset the camera format and the app set it again) and `data.audio_device`. A take normally logs `preview` to `recording` before `session_start` and `recording` to `preview` after the `track_stop` events.
- A `warning` with `data.source: devices` means a device was found again under a new uid (it moved to another USB port).
- A `warning` with `data.source: preflight` repeats a preflight warning that was on at Start, with its `id`, for example `app.dock_covers_frame` (a visible Dock covers part of the frame, or can move onto it from another display, so it is in screen.mov), `app.hot_corner` (a hot corner with an action sits at an edge the frame reaches: the pointer there puts the action in screen.mov), `camera.not_4k` (the capture card gets less than 4K), `camera.empty_frames` (the open camera sends flat frames, one value everywhere; all-zero frames block Start instead) or `screen.refresh-rate` (the display refresh rate does not fit the screen rate). `camera.usb2` (a capture card on a USB link under 5 Gb/s that cannot carry its signal, see `usb_link`) blocks Start, so it is not repeated here.
- A `warning` with `data.source: camera` and a `message` "… changed to 3840x2160 29.97 (was 3840x2160 23.976)." (or "(was 1920x1080)" for a new size) means the camera's HDMI signal changed during the take. camera.mov keeps the size and the grid it started with, so after it the file misses frames or repeats them (`other_size_frames`, `slots_skipped`): the app shows the camera file as having a problem.
- A `warning` with `data.source: app` "The Mac went to sleep, so the take stopped." comes before the `track_stop` lines when the Mac went to sleep during the take: the app stopped both files at the sleep (the stop may finish after the Mac wakes).
- A `warning` with `data.source: control_bar` means a control bar app button did not switch: macOS did not bring the app forward, so its window was not snapped (no `window_snap` follows). `data`: `bundle_id` (the pinned app), `front_bundle_id` (the app that stayed in front), `message`.
- A `warning` with `data.source: screen` and "Hide other windows is on, but …" means a window capture was asked for but the frame region was recorded: no window was snapped, or the snapped window keeps its toolbar above the frame.
- A `warning` with `data.source: keystrokes` "The keystroke pill's window was not found, so keystrokes are not in screen.mov." (1.6): Include keystrokes in screen.mov was on, but screen capture did not list the pill's window at Start (`keystrokes_in_screen` is `off`).
- A `warning` with `data.track: screen_video` means the recorded window of a `window` capture left the screen or came back. Without the keystroke pill: "The recorded window closed; the last frame repeats until it returns." With the pill (1.6, `keystrokes_in_screen` `on`): "The recorded window is not on screen (closed, minimized, hidden or on another Space); screen.mov is black, with the keystroke pill, until it returns.", logged about 1 s after the change. Both end with "The recorded window is back." when it returns.

Each line is in the file when it is written, so events survive a crash of the app.

## voice.jsonl

When the speaker talks (1.4): the replay's Skip silence reads it for a saved take, and an editor can use it for a first rough cut. Written once at Stop, next to events.jsonl, when a mic was recorded (a take that crashed has none). One JSON object per line.

The voice rule is the camera mic detector's (see Mic source fields; its evidence gate does not apply here): a 50 ms block is voiced when its RMS is 10 dB above that mic's noise floor (the lowest block level of the last 3 s) and above -65 dBFS. Voiced blocks less than 200 ms apart join into one stretch; a stretch needs 150 ms of voiced blocks, so a keystroke or a click is no speech. Both mics are kept: `camera_mic` (camera.mov A1, the dialogue) and `screen_mic` (screen.mov A1; in Camera mode the metered, not recorded, Mac mic).

```
{"block_ms":"50","camera_mic_heard":"true","camera_mic_voiced_s":"812.35","origin_host_ns":"1234000000000","preferred":"camera_mic","rule":"…","screen_mic_heard":"true","screen_mic_voiced_s":"798.10","type":"header","version":"1"}
{"end_s":3.4,"source":"camera_mic","start_s":1.25,"type":"speech"}
{"end_s":3.35,"source":"screen_mic","start_s":1.3,"type":"speech"}
```

| Field | Meaning |
|---|---|
| `type` | `header` (the first line) or `speech` (one stretch of one mic). |
| `origin_host_ns` | Header: session.json `started_at_host_ns`. Every `start_s` and `end_s` counts from it, like a flag's `elapsed_s`: they are times in camera.mov and screen.mov (each file begins within a few ms of it, see `first_pts_host_ns`). A stretch that began before it starts at 0. |
| `preferred` | Header: the mic the replay follows first: `camera_mic`, else `screen_mic` when the camera mic sent no audio, or heard less than a quarter of the Mac mic's voice once the Mac mic heard 5 s (a silent camera mic). Missing when neither mic was heard. |
| `camera_mic_voiced_s`, `screen_mic_voiced_s` | Header: voiced time of each mic, in seconds. |
| `camera_mic_heard`, `screen_mic_heard` | Header: the mic sent audio during the take. |
| `block_ms`, `rule`, `version` | Header: the block length (`50`), the voice rule in words, and this file's version (`1`). |
| `source` | Speech: `camera_mic` or `screen_mic`. |
| `start_s`, `end_s` | Speech: the stretch, in seconds since `origin_host_ns`, two decimals (a block is 50 ms). Lines of one source are in time order. |

Skip silence plays each `preferred` stretch, and each stretch of the other mic with no `preferred` stretch within 2 s of it (the camera mic was silent then: a Rode unplugged for a few minutes of the take). It joins stretches less than 1 s apart (the pause plays) and keeps 0.25 s before and after each, so it jumps over pauses longer than 1 s. A rough cut can use the same rule. The flush to the disk follows on a background queue, so logging never holds a capture queue.
