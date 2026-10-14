// CameraCapture: the camera half of a session. It records the capture card (for example an
// Elgato Cam Link 4K) and its HDMI audio into camera.mov: an AVCaptureSession with a full-size
// video data output and an audio data output, written by AVAssetWriter on an exact
// constant-frame-rate grid (CameraWriterController, CameraFrameGrid).
//
// This module owns every AVFoundation device list in the app, cameras and microphones, so the
// screen mic picker also reads `CaptureDevices`.
//
// Clock: every sample buffer timestamp from an AVCaptureSession is on the session's
// `synchronizationClock`. The recorder converts each timestamp to the host clock with
// `CMSyncConvertTime` at the moment the sample arrives, so `first_pts_host_ns` is on the same
// clock as `HostClock.nowNs()` even when the session runs on an audio device clock. Frame times
// are then corrected for a camera that stamps a nominal frame interval (FrameClockRecovery).
