# Net Camera

Net Camera displays the output from any USB-based camera on your macOS desktop. It
supports mirroring (horizontal and vertical), rotation in 90° increments, resizing
to any size, a borderless always-on-top mode, aspect-ratio locking, and saving
stills as PNG. Cameras can be hot-plugged and the app follows them.

The everyday use it is built around is a USB HDMI capture dongle as a
picture-in-picture monitor — watching a bare-metal machine's video output in a
window on another desktop, alongside whatever else that machine is doing.

## An official fork of Quick Camera

Net Camera is a fork of [Quick Camera](https://github.com/simonguest/quick-camera)
by **Simon Guest**, taken up with the full git history intact — every commit Simon
and the other Quick Camera contributors authored is still in this repository's log,
under their names. Net Camera is licensed under the Apache License 2.0, the same
licence Quick Camera uses; see [LICENSE](LICENSE).

Quick Camera is still developed and published by Simon, and it is still on the
[Mac App Store](https://itunes.apple.com/us/app/qcamera/id598853070?mt=12). If what
you want is a USB camera on your desktop and nothing more, use Quick Camera — it is
the better answer for that, deliberately.

### Why the projects differ

Quick Camera does one thing well: it puts a camera on your screen, stays small, and
stays out of the way. That focus is a design position, not an oversight, and it is
why the project declines features that would cost it.

Net Camera wants more than that one thing, and accepts the price. Where Quick
Camera's video frames exist only to be drawn into a preview layer, Net Camera is
built around access to the frames themselves, so that the picture can be observed by
more than just the window — and it pays for that in CPU where Quick Camera does not
have to.

Two projects, two different bargains. Neither is a criticism of the other.

### What changed from Quick Camera

- Rebranded as Net Camera, bundle identifier `com.xalior.NetCamera`, with its own
  Apple developer identity. Quick Camera's identity and App Store presence are
  Simon's and are untouched.
- A `Makefile` so builds and launches are runnable from a terminal without Xcode's UI.

Beyond that, this is Quick Camera's behaviour, unchanged. The frame-based pipeline
and the features it enables are being built and are **not** in this repository yet;
nothing above claims otherwise.

## Building

Requires Xcode. Either open `Quick Camera.xcodeproj`, or from the command line:

```bash
make build     # build the app
make run       # build, then launch it
make clean     # remove build products
```

`make build` defaults to the Debug configuration; pass `CONFIGURATION=Release` for a
release build.

The Xcode project, target, source folder and source filenames still carry the Quick
Camera name. That is intentional: keeping them identical to upstream is what lets
changes flow between the two projects without spurious conflicts.

## Standing on shoulders

Net Camera exists because other people's work exists. Everything it is built on,
credited in full:

- **[Quick Camera](https://github.com/simonguest/quick-camera)** by
  [Simon Guest](https://github.com/simonguest) (Apache-2.0) — not a dependency but
  the origin: Net Camera is its fork, and the great majority of this codebase is
  still Simon's and his contributors' work.
- **Apple's platform frameworks** — AVFoundation for capture, AppKit for the
  interface, IOKit for USB hot-plug detection, Core Graphics and Core Image for
  pixels. Where the platform framework is the mainstream answer, Net Camera uses it
  rather than reaching for a third-party library.

## Licence

Apache License 2.0. See [LICENSE](LICENSE).

Portions copyright © Simon Guest and the Quick Camera contributors.
