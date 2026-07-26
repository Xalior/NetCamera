# Net Camera — project context

Net Camera is a macOS utility that displays a USB camera's output in a window. It is
an Apache-2.0 fork of [Quick Camera](https://github.com/simonguest/quick-camera) by
Simon Guest, carrying that project's full git history. See [README.md](README.md)
for how the two projects differ.

## Technical stack

- **Swift**, **AppKit** — traditional `NSApplication` with Interface Builder, not
  SwiftUI. Do not suggest SwiftUI solutions; the UI lives in
  `Quick Camera/Base.lproj/MainMenu.xib` with `@IBOutlet` / `@IBAction` wiring.
- **AVFoundation** for capture, **IOKit** for USB hot-plug notifications,
  **Core Graphics** for stills.
- **Sandboxed.** `Quick Camera/Quick Camera.entitlements` grants exactly
  `app-sandbox`, `device.camera`, and `files.user-selected.read-write`. The sandbox
  stays on — this app targets the Mac App Store, which requires it. Any capability
  needing more must be expressed as a sandbox-compatible entitlement, and any API
  used must be App Store-clean.
- **Deployment target: macOS 12.4.** Settings persist via `UserDefaults`, not
  SwiftData or Core Data.

## Naming: why the tree says "Quick Camera"

The *product* is "Net Camera" — app name, bundle identifier `com.xalior.NetCamera`,
and every user-visible string. The *tree* is not: the Xcode project file, the build
target, the `Quick Camera/` source folder, the `QC*` filenames and class names, and
the `Info.plist` / entitlements filenames all still carry the upstream name.

That is deliberate, and it is load-bearing. Keeping the tree byte-identical to
upstream's layout is what lets changes move between the two projects without
manufactured conflicts. **Do not rename source files, classes, folders, the Xcode
target, or the project** as a tidying exercise. `PRODUCT_NAME` is set explicitly to
`Net Camera` in both build configurations, which is how the built bundle comes out
correctly branded without any rename.

## Architecture

Three Swift files:

- **`QCAppDelegate.swift`** — the whole application controller: capture session
  setup, every menu action, window management, settings coordination.
- **`QCSettingsManager.swift`** — `QCSettingsManager.shared` singleton persisting
  device selection, mirror states, rotation position, window frame and borderless
  mode to `UserDefaults`.
- **`QCUsbWatcher.swift`** — IOKit `kIOUSBDeviceClassName` notifications, reported
  through `QCUsbWatcherDelegate`. There is a 0.5 s delay after detection because
  macOS needs that long to finish setting up the capture device.

### Capture and display

Frames currently never leave the preview layer: an `AVCaptureSession` feeds an
`AVCaptureVideoPreviewLayer` which is set directly as the window view's layer. There
is no `AVCaptureVideoDataOutput` — nothing in the process can read a frame's pixels.

Consequently **rotation and mirroring are display transforms, not capture
transforms**: they are applied to the *preview layer's connection*
(`setRotation`, `isVideoMirrored`). Anything added at the session level does not
inherit them. This matters for any feature that needs the same picture the window
shows.

Rotation is 4 positions (0–3) = 0°, 90°, 180°, 270°, and interacts with the
upside-down setting. Window dimensions swap at 90° and 270°.

### Saving stills

`Save Image` screenshots the window with `CGWindowListCreateImage`, not by reading
capture frames — including a 0.1 s `RunLoop` pause to let the window repaint first.
Note that `CGWindowListCreateImage` is **deprecated as of macOS 14** and is a
liability for App Store submission.

## Building

```bash
make build     # Debug; pass CONFIGURATION=Release for release
make run       # build, then launch
make clean
```

`xcodebuild` on some machines emits unrelated `CoreSimulator is out of date` and
`Unable to load simulator devices` errors. This is a macOS-only project, so that
output is noise — **judge build success by the exit status, never by the log**.

There is no `Package.swift`; upstream removed it. There is no test target yet.

## Working on this codebase

- Keep the existing conventions: `// MARK: -` section comments, computed properties
  that delegate to `QCSettingsManager`, `NSLog` for tracing, `NSAlert` for
  user-facing errors.
- Adding a setting means touching `QCSettingsManager` (property, setter,
  `loadSettings()`, `saveSettings()`, `logSettings()`) and then `applySettings()` in
  the delegate if it affects what is displayed.
- Adding a transformation means an `IBAction`, a menu item in the XIB, and thinking
  through how it composes with rotation position and both mirror states.
- Prefer a mainstream, licence-compatible library over hand-rolling — and prefer
  Apple's platform framework over a third-party library where the platform framework
  is the mainstream answer. Every dependency earns a credit in the README's
  *Standing on shoulders* section.
- `GCC_PREFIX_HEADER` in both build configurations points at
  `QCamera/QCamera-Prefix.pch`, which does not exist anywhere in the tree. It is
  inert today because there are no C or Objective-C sources, but it will bite the
  moment one is added.
