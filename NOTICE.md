# Third-party notices

TwinTake is MIT licensed (see [LICENSE](LICENSE)). Some files contain code adapted from two other MIT-licensed projects. Each of those files starts with a "Portions adapted from" comment. This file lists them and reproduces both licenses, as the MIT License requires.

## BetterCapture

<https://github.com/jsattler/BetterCapture>, Copyright (c) 2026 Joshua Sattler, MIT License.

| File | What was adapted |
|---|---|
| `Sources/CameraCapture/CameraRecorder.swift` | Starting the capture session on a private queue with a continuation; committing the configuration on failure paths |
| `Sources/CameraCapture/CaptureDevices.swift` | Discovery device types; the connect and disconnect notification pattern |
| `Sources/CameraCapture/OutputSettings.swift` | Codec switch, compression properties, linear PCM keys |
| `Sources/MediaWriter/AudioPipeline.swift` | Passing captured audio samples to the writer |
| `Sources/MediaWriter/GridMath.swift` | Snapping frames to a constant-rate grid (reworked for exact rational rates; shared by camera.mov and screen.mov) |
| `Sources/MediaWriter/PCMSampleBuffers.swift` | Building silent and retimed linear PCM sample buffers |
| `Sources/MediaWriter/WriterSettings.swift` | AVAssetWriter container, video and audio settings (shared by camera.mov and screen.mov) |
| `Sources/ScreenCapture/CFRGrid.swift` | Snapping frames to a constant-rate grid (reworked for exact rational rates) |
| `Sources/ScreenCapture/ScreenRecorder.swift` | SCStream setup and delegate handling |
| `Sources/ScreenCapture/ScreenStreamSettings.swift` | SCStreamConfiguration mapping |
| `Sources/ScreenCapture/ScreenWriterSettings.swift` | AVAssetWriter video and audio settings |
| `Sources/ScreenCapture/VideoPipeline.swift` | Passing captured frames to the writer |
| `Sources/WindowTools/DisplayInfo.swift` | Description of the global display coordinate space |
| `Sources/WindowTools/FrameOverlay.swift` | Click-through overlay panel setup |
| `Sources/RecorderApp/MenuBarLabel.swift` | Drawing the elapsed time into a fixed-width menu bar image |

```
MIT License

Copyright (c) 2026 Joshua Sattler

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Rectangle

<https://github.com/rxhanson/Rectangle>, Copyright (c) 2019-2026 Ryan Hanson, MIT License.

| File | What was adapted |
|---|---|
| `Sources/WindowTools/AXWindow.swift` | Accessibility get and set helpers; size, then position, then size; the `AXEnhancedUserInterface` toggle |
| `Sources/WindowTools/WindowList.swift` | CGWindowList parsing; matching a window by process and frame |
| `Sources/WindowTools/WindowSnapper.swift` | Front window selection; the frame change flow |

```
MIT License

Copyright (c) 2019-2026 Ryan Hanson
Based on the Spectacle app, Copyright (c) 2017 Eric Czarny eczarny@gmail.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
