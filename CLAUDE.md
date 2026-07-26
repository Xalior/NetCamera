# Net Camera — project context

Net Camera is a macOS utility that displays a USB camera's output in a window. It is
an Apache-2.0 fork of [Quick Camera](https://github.com/simonguest/quick-camera) by
Simon Guest, carrying that project's full git history. See [README.md](README.md)
for how the two projects differ.

## Technical stack

- **Swift**, **AppKit** — traditional `NSApplication` with Interface Builder, not
  SwiftUI. Do not suggest SwiftUI solutions; the UI lives in
  `Net Camera/Base.lproj/MainMenu.xib` with `@IBOutlet` / `@IBAction` wiring.
- **AVFoundation** for capture, **IOKit** for USB hot-plug notifications,
  **Core Graphics** for stills.
- **Sandboxed.** `Net Camera/Net Camera.entitlements` grants exactly
  `app-sandbox`, `device.camera`, and `files.user-selected.read-write`. The sandbox
  stays on — this app targets the Mac App Store, which requires it. Any capability
  needing more must be expressed as a sandbox-compatible entitlement, and any API
  used must be App Store-clean.
- **Deployment target: macOS 12.4.** Settings persist via `UserDefaults`, not
  SwiftData or Core Data.

## Naming, and the nib class references that depend on it

The product and the tree agree: "Net Camera" is the app name, the bundle identifier
`com.xalior.NetCamera`, the Xcode project and target, the `Net Camera/` source
folder, the `Info.plist` and entitlements filenames, and every user-visible string.
Classes carry the `NC` prefix. Upstream's *branding* is gone from the tree;
upstream's *credit* stays — the `LICENSE`, the README's fork provenance and
*Standing on shoulders* credits, and the `Info.plist` "Portions copyright © 2025
Simon Guest" are a separate obligation and must survive any future sweep.

`PRODUCT_MODULE_NAME` is deliberately **not** set. The Swift module name therefore
derives from `PRODUCT_NAME` run through `c99extidentifier`, giving `Net_Camera`.

That derivation is load-bearing, because **nib class references are
module-qualified**: `MainMenu.xib` names the delegate as `Net_Camera.NCAppDelegate`.
Change `PRODUCT_NAME`, or rename the delegate class, and the nib must change in the
same commit or the app breaks — and it breaks **silently and in disguise**. The
build still succeeds. The app still launches. A window still opens, wearing the
title baked into the nib. But the class lookup fails, so no delegate is
instantiated, `applicationDidFinishLaunching` never runs, no capture session
starts, and AppKit auto-disables every menu item whose action targets the delegate.
It presents as a camera or permissions fault rather than a class-lookup one.

**A green build proves nothing about this.** The check that discriminates is the
window title: the nib's baked title is the bare string `Net Camera`, so a working
app is the one whose title becomes `Net Camera: [<device>]` — the device name is
something only the running delegate can supply.

## Architecture

Three Swift files:

- **`NCAppDelegate.swift`** — the whole application controller: capture session
  setup, every menu action, window management, settings coordination.
- **`NCSettingsManager.swift`** — `NCSettingsManager.shared` singleton persisting
  device selection, mirror states, rotation position, window frame and borderless
  mode to `UserDefaults`.
- **`NCUsbWatcher.swift`** — IOKit `kIOUSBDeviceClassName` notifications, reported
  through `NCUsbWatcherDelegate`. There is a 0.5 s delay after detection because
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

### Resolution selection

Each camera in *Select Source* owns a submenu listing every distinct `WxH` its
formats advertise, and `NCAppDelegate.chosenFormatIndex` remembers the pick per
camera by `uniqueID`. The pick has to be re-applied on every capture start:
adding an input to a fresh `AVCaptureSession` lets the session preset choose the
format, so a choice made earlier is otherwise discarded whenever the user
switches camera and back, or a hot-plug restarts capture.

Two constraints worth knowing before touching this:

- **A camera's `activeFormat` is shared process-wide, and other apps move it.**
  Running `imagesnap` against a camera Net Camera is showing resets that camera
  to the preset `imagesnap` asks for and leaves it there. Both apps keep working
  — co-existence is intact — but Net Camera is then capturing at a resolution its
  menu does not name, until the next menu action refreshes it. AVFoundation
  offers no notification of another process's reconfiguration.
- **Net Camera reports what the hardware advertises and does not audit it.**
  The "USB3.0 HD VIDEO" dongle genuinely serves only 1080p while advertising ten
  other sizes; selecting one of them yields a broken picture. That is the
  device lying, not a bug here, and it must not be "fixed" with format
  filtering.

Menu state in *Select Source* is derived, never remembered:
`refreshSourceMenuState()` recomputes every checkmark from the session's device
and each device's `activeFormat`. Resolution items match on dimensions rather
than format identity, because a camera advertises each size once per pixel
format while the menu lists each size once.

Because every camera item owns a submenu, **AppKit will not fire an action or a
key equivalent on it** — a menu item with a submenu does neither. Selecting the
camera therefore lives on the submenu's first item, *Use This Camera*, which
carries the action and the ⌘N shortcut. Anything that puts a submenu on a menu
item has to account for this; the failure is silent, and looks like a dead menu.

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
  that delegate to `NCSettingsManager`, `NSLog` for tracing, `NSAlert` for
  user-facing errors.
- Adding a setting means touching `NCSettingsManager` (property, setter,
  `loadSettings()`, `saveSettings()`, `logSettings()`) and then `applySettings()` in
  the delegate if it affects what is displayed.
- Adding a transformation means an `IBAction`, a menu item in the XIB, and thinking
  through how it composes with rotation position and both mirror states.
- Prefer a mainstream, licence-compatible library over hand-rolling — and prefer
  Apple's platform framework over a third-party library where the platform framework
  is the mainstream answer. Every dependency earns a credit in the README's
  *Standing on shoulders* section.
- Inherited defect: **saved window geometry is never restored.** `Save Settings`
  writes `frameW`/`frameH`/`frameX`/`frameY` correctly, and `loadSettings()` reads
  them and calls `setContentSize`, but the window still comes up at its nib size.
  Confirmed identical before and after the PR #59 merge, so it is upstream's, not
  ours. Every other saved setting — mirror, upside-down, rotation, borderless,
  aspect-ratio lock — does restore.
