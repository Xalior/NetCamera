import AVFoundation
import AVKit
import Cocoa
import ImageIO
import UniformTypeIdentifiers

// MARK: - NCAppDelegate Class
@NSApplicationMain
class NCAppDelegate: NSObject, NSApplicationDelegate, NCUsbWatcherDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{

    // MARK: - USB Watcher
    let usb: NCUsbWatcher = NCUsbWatcher()
    func deviceCountChanged() {
        self.detectVideoDevices()
        self.startCaptureWithVideoDevice(defaultDevice: selectedDeviceIndex)
    }

    // MARK: - Interface Builder Outlets
    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var selectSourceMenu: NSMenuItem!
    @IBOutlet weak var borderlessMenu: NSMenuItem!
    @IBOutlet weak var aspectRatioFixedMenu: NSMenuItem!
    @IBOutlet weak var mirroredMenu: NSMenuItem!
    @IBOutlet weak var upsideDownMenu: NSMenuItem!
    @IBOutlet weak var playerView: NSView!

    // MARK: - Settings Properties
    var isMirrored: Bool {
        get { NCSettingsManager.shared.isMirrored }
        set { NCSettingsManager.shared.setMirrored(newValue) }
    }
    var isUpsideDown: Bool {
        get { NCSettingsManager.shared.isUpsideDown }
        set { NCSettingsManager.shared.setUpsideDown(newValue) }
    }
    var position: Int {
        get { NCSettingsManager.shared.position }
        set { NCSettingsManager.shared.setPosition(newValue) }
    }
    var isBorderless: Bool {
        get { NCSettingsManager.shared.isBorderless }
        set { NCSettingsManager.shared.setBorderless(newValue) }
    }
    var isAspectRatioFixed: Bool {
        get { NCSettingsManager.shared.isAspectRatioFixed }
        set { NCSettingsManager.shared.setAspectRatioFixed(newValue) }
    }
    var deviceName: String {
        get { NCSettingsManager.shared.deviceName }
        set { NCSettingsManager.shared.setDeviceName(newValue) }
    }

    // MARK: - Window Properties
    var defaultBorderStyle: NSWindow.StyleMask = NSWindow.StyleMask.closable
    var windowTitle: String = "Net Camera"
    let defaultDeviceIndex: Int = 0
    var selectedDeviceIndex: Int = 0

    var savedDeviceName: String = "-"
    var devices: [AVCaptureDevice]!
    var captureSession: AVCaptureSession!
    var videoOutput: AVCaptureVideoDataOutput!

    var input: AVCaptureDeviceInput!

    // MARK: - Frame Pipeline
    /// Where frames are delivered and processed. One serial queue, so the
    /// transform's buffer pool and every sink see frames one at a time and in
    /// the order the camera produced them, and nothing on it ever waits for
    /// the main thread.
    let captureQueue: DispatchQueue = DispatchQueue(label: "com.xalior.NetCamera.capture")

    let frameTransform: NCFrameTransform = NCFrameTransform()
    let frameDistributor: NCFrameDistributor = NCFrameDistributor()
    let displaySink: NCDisplaySink = NCDisplaySink()

    // MARK: - Netcam
    /// The embedded web server. Always on: there is no toggle, because a netcam
    /// that has to be switched on is a netcam that is off when it is wanted.
    let httpServer: NCHTTPServer = NCHTTPServer()

    /// The picture as it goes out over the network. A sink like the window's,
    /// registered on the same distributor and handed the same processed frame,
    /// which is what makes the browser and the window show the same thing.
    let mjpegSink: NCMJPEGSink = NCMJPEGSink()

    /// The orientation given to every frame. Menu actions write it on the main
    /// thread and the capture queue reads it once per frame, so it is guarded
    /// by a lock. It is also a value copied out of the settings rather than a
    /// look at them: the settings and the menus belong to the main thread, and
    /// this is the only application state the capture queue ever sees.
    private let orientationLock: NSLock = NSLock()
    private var frameOrientation: NCFrameOrientation = NCFrameOrientation(
        position: 0, isMirrored: false, isUpsideDown: false)

    /// Whether the current run of dropped frames has already been traced.
    /// Capture queue only.
    private var frameDropReported: Bool = false

    private func publish(_ orientation: NCFrameOrientation) {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        frameOrientation = orientation
    }

    private var currentFrameOrientation: NCFrameOrientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return frameOrientation
    }

    // MARK: - Error Handling
    func errorMessage(message: String) {
        let popup: NSAlert = NSAlert()
        popup.messageText = message
        popup.runModal()
    }

    // MARK: - Device Management

    /// Rebuilds the device list and the whole of the Select Source menu.
    ///
    /// Called at launch and again on every USB hot-plug, which means it can run
    /// **while the menu the user is looking at is open** — plug a camera in with
    /// Select Source pulled down and the new device appears in it there and then,
    /// and can be chosen without closing anything.
    ///
    /// That is worth preserving deliberately, because it is not something AppKit
    /// owes anybody: a menu ordinarily settles its contents when it opens. It
    /// survives here because the submenu is replaced wholesale rather than
    /// mutated item by item, and because the watcher's settling delay means the
    /// capture device is ready by the time the item exists to be clicked.
    /// Rebuilding this incrementally, or acting on the hot-plug sooner, would
    /// each take it away — and would do so silently, since nothing about a menu
    /// that is merely stale looks broken.
    func detectVideoDevices() {
        NSLog("Detecting video devices...")
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified)
        self.devices = discoverySession.devices
        if devices.isEmpty {
            let popup: NSAlert = NSAlert()
            popup.messageText =
                "Unfortunately, you don't appear to have any cameras connected. Goodbye for now!"
            popup.runModal()
            NSApp.terminate(nil)
        } else {
            NSLog("%d devices found", devices.count)
        }

        let deviceMenu: NSMenu = NSMenu()
        var deviceIndex: Int = 0

        if self.captureSession == nil {
            NSLog("first time - loadSettings")
            self.loadSettings()
        }
        // Fall back to the first device: if the selected one has just been unplugged there is
        // no session device left to match against. refreshSourceMenuState() settles the real
        // selection once the menu is built.
        self.selectedDeviceIndex = defaultDeviceIndex

        for device: AVCaptureDevice in self.devices {
            // The device item carries neither an action nor a key equivalent. AppKit fires
            // neither on a menu item that owns a submenu, and every device owns one — so both
            // live on the submenu's "Use This Camera" item instead. The item keeps its
            // checkmark, which is display state and works on a submenu owner.
            let deviceMenuItem: NSMenuItem = NSMenuItem(
                title: device.localizedName, action: nil, keyEquivalent: "")
            deviceMenuItem.representedObject = deviceIndex

            // Every device carries its resolution submenu. Net Camera's audience wants the
            // control, so it is unconditional rather than hidden behind a preference.
            addResolutionsTo(menuItem: deviceMenuItem, forDevice: device, deviceIndex: deviceIndex)

            deviceMenu.addItem(deviceMenuItem)
            deviceIndex += 1
        }

        selectSourceMenu.submenu = deviceMenu
        refreshSourceMenuState()
    }

    /// The device the capture session is currently running on, or nil before the first
    /// session exists.
    var activeCaptureDevice: AVCaptureDevice? {
        (self.captureSession?.inputs.first as? AVCaptureDeviceInput)?.device
    }

    /// Recompute every checkmark in Select Source from what the hardware is actually doing —
    /// the session's device, and that device's activeFormat. Menu state is derived rather
    /// than remembered, so it cannot drift from the capture state it claims to describe.
    func refreshSourceMenuState() {
        guard let deviceMenu = selectSourceMenu.submenu, self.devices != nil else { return }
        let activeDevice =
            self.activeCaptureDevice
            ?? (self.devices.indices.contains(selectedDeviceIndex)
                ? self.devices[selectedDeviceIndex] : self.devices.first)

        for deviceMenuItem: NSMenuItem in deviceMenu.items {
            guard let deviceIndex = deviceMenuItem.representedObject as? Int,
                self.devices.indices.contains(deviceIndex)
            else { continue }
            let device: AVCaptureDevice = self.devices[deviceIndex]
            let isActive: Bool = (device == activeDevice)
            deviceMenuItem.state = isActive ? .on : .off
            if isActive { self.selectedDeviceIndex = deviceIndex }

            let activeDims = CMVideoFormatDescriptionGetDimensions(
                device.activeFormat.formatDescription)
            for item: NSMenuItem in deviceMenuItem.submenu?.items ?? [] {
                guard let index = item.representedObject as? Int else { continue }
                if item.action == #selector(deviceMenuChanged) {
                    item.state = isActive ? .on : .off
                } else if device.formats.indices.contains(index) {
                    // Resolution items are matched on dimensions, not on format identity: the
                    // submenu lists each WxH once, so the active format is often a later
                    // same-size entry that no menu item stands for individually.
                    let dims = CMVideoFormatDescriptionGetDimensions(
                        device.formats[index].formatDescription)
                    item.state =
                        (dims.width == activeDims.width && dims.height == activeDims.height)
                        ? .on : .off
                }
            }
        }
    }

    func startCaptureWithVideoDevice(defaultDevice: Int) {
        NSLog("Starting capture with device index %d", defaultDevice)
        let device: AVCaptureDevice = self.devices[defaultDevice]

        if captureSession != nil {

            // if we are "restarting" a session but the device is the same exit early
            let currentDevice: AVCaptureDevice =
                (self.captureSession.inputs[0] as! AVCaptureDeviceInput).device
            guard currentDevice != device else {
                // A USB hot-plug lands here: the session is left alone, but re-assert the
                // chosen resolution in case the device was reconfigured behind us.
                self.applyChosenResolution(to: device)
                return
            }

            // Late callbacks from the outgoing session would carry the old
            // camera's picture into the new one's window.
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            captureSession.stopRunning()
        }
        captureSession = AVCaptureSession()

        do {
            self.input = try AVCaptureDeviceInput(device: device)
            self.captureSession.addInput(input)

            self.videoOutput = AVCaptureVideoDataOutput()
            // BGRA is what the transform renders into and what every consumer
            // of the frame reads.
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            // A frame that arrives late is worth less than the one behind it,
            // so the newest picture wins rather than a backlog forming.
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.captureQueue)

            guard self.captureSession.canAddOutput(self.videoOutput) else {
                NSLog("The session will not take a video data output")
                self.errorMessage(
                    message:
                        "Unfortunately, this camera cannot deliver frames to Net Camera. Try a different one."
                )
                return
            }
            self.captureSession.addOutput(self.videoOutput)

            // The connection hands over the camera's own picture and nothing
            // else: orientation belongs to NCFrameTransform, which every
            // consumer of the frame shares. The built-in FaceTime camera
            // mirrors itself unless told not to, and that mirror would compose
            // on top of the transform — mirroring the picture on one camera
            // and not on another, with no setting saying so.
            if let connection: AVCaptureConnection = self.videoOutput.connection(with: .video),
                connection.isVideoMirroringSupported
            {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }

            self.captureSession.startRunning()

            self.windowTitle = String(format: "Net Camera: [%@]", device.localizedName)
            self.window.title = self.windowTitle
            self.deviceName = device.localizedName
            // Before applySettings, which sizes the window from the format now in force.
            self.applyChosenResolution(to: device)
            self.applySettings()
        } catch {
            NSLog("Error while opening device")
            self.errorMessage(
                message:
                    "Unfortunately, there was an error when trying to access the camera. Try again or select a different one."
            )
        }
    }

    // MARK: - Settings Management
    func logSettings(label: String) {
        NCSettingsManager.shared.logSettings(label: label)
    }

    func loadSettings() {
        NCSettingsManager.shared.loadSettings()

        if self.isBorderless {
            self.removeBorder()
        }

        let savedW = NCSettingsManager.shared.frameWidth
        let savedH = NCSettingsManager.shared.frameHeight
        if 100 < savedW && 100 < savedH {
            let savedX = NCSettingsManager.shared.frameX
            let savedY = NCSettingsManager.shared.frameY
            NSLog("loaded : x:%f,y:%f,w:%f,h:%f", savedX, savedY, savedW, savedH)
            var currentSize: CGSize = self.window.contentLayoutRect.size
            currentSize.width = CGFloat(savedW)
            currentSize.height = CGFloat(savedH)
            self.window.setContentSize(currentSize)
            self.window.setFrameOrigin(NSPoint(x: CGFloat(savedX), y: CGFloat(savedY)))
        }
    }

    func applySettings() {
        NCSettingsManager.shared.logSettings(label: "applySettings")

        // The three settings that decide which way round the picture is, handed
        // to the pipeline as one value. Every consumer sees the same geometry
        // because they all read the same processed frame.
        self.publish(
            NCFrameOrientation(
                position: self.position, isMirrored: self.isMirrored,
                isUpsideDown: self.isUpsideDown))
        self.fixAspectRatio()

        self.borderlessMenu.state = convertToNSControlStateValue(
            (isBorderless ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        self.mirroredMenu.state = convertToNSControlStateValue(
            (isMirrored ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        self.upsideDownMenu.state = convertToNSControlStateValue(
            (isUpsideDown ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        self.aspectRatioFixedMenu.state = convertToNSControlStateValue(
            (isAspectRatioFixed
                ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
    }

    // MARK: - Settings Actions
    @IBAction func saveSettings(_ sender: NSMenuItem) {
        NCSettingsManager.shared.setFrameProperties(
            x: Float(self.window.frame.minX),
            y: Float(self.window.frame.minY),
            width: Float(self.window.frame.width),
            height: Float(self.window.frame.height)
        )
        NCSettingsManager.shared.saveSettings()
    }

    @IBAction func clearSettings(_ sender: NSMenuItem) {
        NCSettingsManager.shared.clearSettings()
    }

    // MARK: - Display Actions
    @IBAction func mirrorHorizontally(_ sender: NSMenuItem) {
        NSLog("Mirror image menu item selected")
        isMirrored = !isMirrored
        self.applySettings()
    }

    @IBAction func mirrorVertically(_ sender: NSMenuItem) {
        NSLog("Mirror image vertically menu item selected")
        isUpsideDown = !isUpsideDown
        self.applySettings()
    }

    func swapWH() {
        var currentSize: CGSize = self.window.contentLayoutRect.size
        swap(&currentSize.height, &currentSize.width)
        self.window.setContentSize(currentSize)
    }

    @IBAction func rotateLeft(_ sender: NSMenuItem) {
        NSLog("Rotate Left menu item selected with position %d", position)
        position = position - 1
        if position == -1 { position = 3 }
        self.swapWH()
        self.applySettings()
    }

    @IBAction func rotateRight(_ sender: NSMenuItem) {
        NSLog("Rotate Right menu item selected with position %d", position)
        position = position + 1
        if position == 4 { position = 0 }
        self.swapWH()
        self.applySettings()
    }

    // MARK: - Display Helpers
    private func addBorder() {
        window.styleMask = defaultBorderStyle
        window.title = self.windowTitle
        self.window.level = convertToNSWindowLevel(Int(CGWindowLevelForKey(.normalWindow)))
        window.isMovableByWindowBackground = false
    }

    private func removeBorder() {
        defaultBorderStyle = window.styleMask
        self.window.styleMask = [NSWindow.StyleMask.borderless, NSWindow.StyleMask.resizable]
        self.window.level = convertToNSWindowLevel(Int(CGWindowLevelForKey(.maximumWindow)))
        window.isMovableByWindowBackground = true
    }

    @IBAction func borderless(_ sender: NSMenuItem) {
        NSLog("Borderless menu item selected")
        if self.window.styleMask.contains(.fullScreen) {
            NSLog("Ignoring borderless command as window is full screen")
            return
        }
        isBorderless = !isBorderless
        sender.state = convertToNSControlStateValue(
            (isBorderless ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        if isBorderless {
            removeBorder()
        } else {
            addBorder()
        }
        fixAspectRatio()
    }

    @IBAction func enterFullScreen(_ sender: NSMenuItem) {
        NSLog("Enter full screen menu item selected")
        playerView.window?.toggleFullScreen(self)
        // no effect when borderless is enabled ?
    }

    @IBAction func toggleFixAspectRatio(_ sender: NSMenuItem) {
        isAspectRatioFixed = !isAspectRatioFixed
        sender.state = convertToNSControlStateValue(
            (isAspectRatioFixed
                ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue))
        fixAspectRatio()
    }

    func isLandscape() -> Bool {
        return position % 2 == 0
    }

    func fixAspectRatio() {
        if isAspectRatioFixed, #available(OSX 10.15, *) {
            let height: Int32 = input.device.activeFormat.formatDescription.dimensions.height
            let width: Int32 = input.device.activeFormat.formatDescription.dimensions.width
            let size: NSSize =
                self.isLandscape()
                ? NSMakeSize(CGFloat(width), CGFloat(height))
                : NSMakeSize(CGFloat(height), CGFloat(width))
            self.window.contentAspectRatio = size

            let ratio: CGFloat = CGFloat(Float(width) / Float(height))
            var currentSize: CGSize = self.window.contentLayoutRect.size
            if self.isLandscape() {
                currentSize.height = currentSize.width / ratio
            } else {
                currentSize.height = currentSize.width * ratio
            }
            NSLog(
                "fixAspectRatio : %f - %d,%d - %f,%f - %f,%f", ratio, width, height, size.width,
                size.height, currentSize.width, currentSize.height)
            self.window.setContentSize(currentSize)
        } else {
            self.window.contentResizeIncrements = NSMakeSize(1.0, 1.0)
        }
    }

    @IBAction func fitToActualSize(_ sender: NSMenuItem) {
        if #available(OSX 10.15, *) {
            let height: Int32 = input.device.activeFormat.formatDescription.dimensions.height
            let width: Int32 = input.device.activeFormat.formatDescription.dimensions.width
            var currentSize: CGSize = self.window.contentLayoutRect.size
            currentSize.width = CGFloat(self.isLandscape() ? width : height)
            currentSize.height = CGFloat(self.isLandscape() ? height : width)
            self.window.setContentSize(currentSize)
        }
    }

    // MARK: - Saving Stills

    /// Writes the picture to a file, as one more consumer of the processed
    /// frame.
    ///
    /// Nothing here photographs the window. The window is a sink like any other
    /// and holds no privileged copy of the picture, so the file is made from the
    /// same frame the window is drawing — at the camera's own resolution, the
    /// way round the user asked for it. What the window happens to be doing is
    /// therefore irrelevant to saving: full screen, the border and the window's
    /// size have no bearing on the file.
    @IBAction func saveImage(_ sender: NSMenuItem) {
        NSLog("Save Image menu item selected")
        NCStillCapture.requestStill(from: self.frameDistributor) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let image):
                self.presentSavePanel(for: image)
            case .failure(let failure):
                // A request that produced nothing says so. Saving that silently
                // does nothing is indistinguishable from a broken menu item.
                NSLog("Save Image failed: %@", String(describing: failure))
                self.errorMessage(message: failure.message)
            }
        }
    }

    /// The save panel: the filename pattern and the PNG write this app has
    /// always had, over an image that now comes from the pipeline.
    private func presentSavePanel(for image: CGImage) {
        let now: Date = Date()
        let dateFormatter: DateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date: String = dateFormatter.string(from: now)
        dateFormatter.dateFormat = "h.mm.ss a"
        let time: String = dateFormatter.string(from: now)

        let panel: NSSavePanel = NSSavePanel()
        panel.nameFieldStringValue = String(format: "Net Camera Image %@ at %@.png", date, time)
        panel.beginSheetModal(for: self.window) { (result: NSApplication.ModalResponse) in
            guard result == NSApplication.ModalResponse.OK, let url: URL = panel.url else { return }
            NSLog("Saving image to %@", url.absoluteString)
            let destination: CGImageDestination? = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
            if destination == nil {
                NSLog(
                    "Could not write file - destination returned from CGImageDestinationCreateWithURL was nil"
                )
                self.errorMessage(
                    message: "Unfortunately, the image could not be saved to this location."
                )
            } else {
                CGImageDestinationAddImage(destination!, image, nil)
                CGImageDestinationFinalize(destination!)
            }
        }
    }

    // MARK: - Device Menu Actions
    @objc func deviceMenuChanged(_ sender: NSMenuItem) {
        NSLog("Device Menu changed")
        guard let deviceIndex = sender.representedObject as? Int,
            self.devices.indices.contains(deviceIndex)
        else { return }

        self.startCaptureWithVideoDevice(defaultDevice: deviceIndex)
        self.refreshSourceMenuState()
    }

    // MARK: - Frame Tap
    /// Every frame the camera produces, oriented and handed to the sinks.
    ///
    /// Runs on the capture queue. It reads the guarded orientation and nothing
    /// else of the application's: no menus, no settings, no window.
    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let source: CVPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            reportFrameDropped(reason: "the sample buffer carried no image buffer")
            return
        }

        guard
            let processed: CVPixelBuffer = self.frameTransform.apply(
                self.currentFrameOrientation, to: source)
        else {
            reportFrameDropped(reason: "no buffer was vended for the oriented frame")
            return
        }

        self.frameDropReported = false
        self.frameDistributor.deliver(
            processed, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    /// Traces the first drop of a run and stays quiet until frames flow again,
    /// so a pipeline that cannot process a frame says so once rather than
    /// thirty times a second.
    private func reportFrameDropped(reason: String) {
        guard !self.frameDropReported else { return }
        self.frameDropReported = true
        NSLog("Dropped a frame: %@", reason)
    }

    // MARK: - Application Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // The window hosts the display sink's layer for the lifetime of the
        // app. It belongs to the picture rather than to any one capture
        // session, and survives every camera change and hot-plug.
        self.playerView.layer = self.displaySink.layer
        self.playerView.layer?.backgroundColor = CGColor.black
        // A renderer that stops taking frames and will not be talked round is
        // replaced wholesale, and the window has to host whatever replaces it.
        self.displaySink.onLayerReplaced = { [weak self] layer in
            self?.playerView.layer = layer
            self?.playerView.layer?.backgroundColor = CGColor.black
        }
        self.frameDistributor.add(self.displaySink)
        // The window first and the network second, because registration order
        // is delivery order and the picture on the desk should not wait behind
        // an encode. With nobody watching the stream, the second sink costs
        // nothing at all.
        self.frameDistributor.add(self.mjpegSink)

        // Before the camera, because the server depends on nothing the camera
        // provides, and because a camera that takes its time — or is not there
        // at all — must not decide whether the app is reachable over the
        // network.
        self.httpServer.start(streaming: self.mjpegSink) { [weak self] failure in
            self?.errorMessage(message: failure.message)
        }

        detectVideoDevices()
        startCaptureWithVideoDevice(defaultDevice: defaultDeviceIndex)
        usb.delegate = self
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // The listener is given up deliberately rather than left to the process
        // exiting, so a quit-and-relaunch always finds the port free.
        self.httpServer.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Resolutions

    /// The resolution chosen for each camera, held as an index into that camera's formats and
    /// keyed by its uniqueID. A camera keeps its own choice, and keeps it while another camera
    /// is on screen.
    var chosenFormatIndex: [String: Int] = [:]

    @objc func sourceResolutionsMenuChanged(_ sender: NSMenuItem) {
        guard let formatIndex = sender.representedObject as? Int,
            let deviceMenuItem = sender.parent,
            let deviceIndex = deviceMenuItem.representedObject as? Int,
            self.devices.indices.contains(deviceIndex)
        else { return }

        self.chosenFormatIndex[self.devices[deviceIndex].uniqueID] = formatIndex
        self.selectedDeviceIndex = deviceIndex

        // Choosing a resolution also chooses its camera, so the device may change here too.
        // startCaptureWithVideoDevice applies the choice on both of its paths.
        self.startCaptureWithVideoDevice(defaultDevice: deviceIndex)
        // Staying on the same camera skips the session rebuild, and with it the window sizing
        // that applySettings does — so relock the window to the shape now being captured.
        self.fixAspectRatio()
        self.refreshSourceMenuState()
    }

    /// Put the camera on the resolution chosen for it, if one has been.
    ///
    /// This runs on every capture start rather than only when the menu is used, because
    /// adding an input to a fresh AVCaptureSession lets the session's preset choose the
    /// format — which silently discards an earlier choice whenever the user switches camera
    /// and back, or a USB hot-plug restarts capture.
    func applyChosenResolution(to device: AVCaptureDevice) {
        guard let formatIndex = self.chosenFormatIndex[device.uniqueID],
            device.formats.indices.contains(formatIndex)
        else { return }

        let format: AVCaptureDevice.Format = device.formats[formatIndex]
        do {
            try device.lockForConfiguration()
        } catch {
            // Another process can hold the device's configuration; losing the race costs the
            // chosen resolution, not the picture, so carry on at whatever format is in force.
            NSLog(
                "Could not lock %@ for configuration: %@", device.localizedName,
                error.localizedDescription)
            return
        }
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        // Run the format as fast as it will go: the shortest frame duration it supports.
        if !format.videoSupportedFrameRateRanges.isEmpty {
            device.activeVideoMinFrameDuration = format.videoSupportedFrameRateRanges.reduce(
                CMTime.positiveInfinity
            ) { CMTimeMinimum($0, $1.minFrameDuration) }
        }
    }

    // MARK: - source resolutions

    /// Build a device's submenu: the item that selects the camera, then one item per
    /// distinct resolution the device advertises. Net Camera reports what the hardware
    /// claims to support; it does not audit whether the hardware can deliver it.
    func addResolutionsTo(menuItem: NSMenuItem, forDevice device: AVCaptureDevice, deviceIndex: Int)
    {
        let resolutionsMenu: NSMenu = NSMenu()

        // Selecting the camera. This carries the action and the Cmd-N key equivalent that the
        // device item itself cannot, because AppKit honours neither on a submenu owner.
        let selectItem: NSMenuItem = NSMenuItem(
            title: "Use This Camera", action: #selector(deviceMenuChanged),
            keyEquivalent: deviceIndex < 9 ? String(deviceIndex + 1) : "")
        selectItem.target = self
        selectItem.representedObject = deviceIndex
        resolutionsMenu.addItem(selectItem)
        resolutionsMenu.addItem(NSMenuItem.separator())

        for (formatIndex, format) in device.formats.enumerated() {
            let menuTitle: String = descriptionFor(resolution: format)
            // Devices advertise the same dimensions once per pixel format, so list each
            // size once and let the first entry of that size stand for it.
            guard resolutionsMenu.indexOfItem(withTitle: menuTitle) == -1 else { continue }

            let resolutionMenuItem: NSMenuItem = NSMenuItem(
                title: menuTitle, action: #selector(sourceResolutionsMenuChanged),
                keyEquivalent: "")
            resolutionMenuItem.target = self
            resolutionMenuItem.representedObject = formatIndex
            resolutionsMenu.addItem(resolutionMenuItem)
        }

        menuItem.submenu = resolutionsMenu
    }

    private func descriptionFor(resolution: AVCaptureDevice.Format) -> String {
        let dims = CMVideoFormatDescriptionGetDimensions(resolution.formatDescription)
        return "\(dims.width)x\(dims.height)"
    }


}

// MARK: - Helper Functions
// Helper function inserted by Swift 4.2 migrator.
private func convertToNSControlStateValue(_ input: Int) -> NSControl.StateValue {
    NSControl.StateValue(rawValue: input)
}

// Helper function inserted by Swift 4.2 migrator.
private func convertToNSWindowLevel(_ input: Int) -> NSWindow.Level {
    NSWindow.Level(rawValue: input)
}
