import AVFoundation
import AVKit
import Cocoa

// MARK: - QCAppDelegate Class
@NSApplicationMain
class QCAppDelegate: NSObject, NSApplicationDelegate, QCUsbWatcherDelegate {

    // MARK: - USB Watcher
    let usb: QCUsbWatcher = QCUsbWatcher()
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
        get { QCSettingsManager.shared.isMirrored }
        set { QCSettingsManager.shared.setMirrored(newValue) }
    }
    var isUpsideDown: Bool {
        get { QCSettingsManager.shared.isUpsideDown }
        set { QCSettingsManager.shared.setUpsideDown(newValue) }
    }
    var position: Int {
        get { QCSettingsManager.shared.position }
        set { QCSettingsManager.shared.setPosition(newValue) }
    }
    var isBorderless: Bool {
        get { QCSettingsManager.shared.isBorderless }
        set { QCSettingsManager.shared.setBorderless(newValue) }
    }
    var isAspectRatioFixed: Bool {
        get { QCSettingsManager.shared.isAspectRatioFixed }
        set { QCSettingsManager.shared.setAspectRatioFixed(newValue) }
    }
    var deviceName: String {
        get { QCSettingsManager.shared.deviceName }
        set { QCSettingsManager.shared.setDeviceName(newValue) }
    }

    // MARK: - Window Properties
    var defaultBorderStyle: NSWindow.StyleMask = NSWindow.StyleMask.closable
    var windowTitle: String = "Net Camera"
    let defaultDeviceIndex: Int = 0
    var selectedDeviceIndex: Int = 0

    var savedDeviceName: String = "-"
    var devices: [AVCaptureDevice]!
    var captureSession: AVCaptureSession!
    var captureLayer: AVCaptureVideoPreviewLayer!

    var input: AVCaptureDeviceInput!

    // MARK: - Error Handling
    func errorMessage(message: String) {
        let popup: NSAlert = NSAlert()
        popup.messageText = message
        popup.runModal()
    }

    // MARK: - Device Management
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

            captureSession.stopRunning()
        }
        captureSession = AVCaptureSession()

        do {
            self.input = try AVCaptureDeviceInput(device: device)
            self.captureSession.addInput(input)
            self.captureSession.startRunning()
            self.captureLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
            self.captureLayer.connection?.automaticallyAdjustsVideoMirroring = false
            self.captureLayer.connection?.isVideoMirrored = false

            self.playerView.layer = self.captureLayer
            self.playerView.layer?.backgroundColor = CGColor.black
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
        QCSettingsManager.shared.logSettings(label: label)
    }

    func loadSettings() {
        QCSettingsManager.shared.loadSettings()

        if self.isBorderless {
            self.removeBorder()
        }

        let savedW = QCSettingsManager.shared.frameWidth
        let savedH = QCSettingsManager.shared.frameHeight
        if 100 < savedW && 100 < savedH {
            let savedX = QCSettingsManager.shared.frameX
            let savedY = QCSettingsManager.shared.frameY
            NSLog("loaded : x:%f,y:%f,w:%f,h:%f", savedX, savedY, savedW, savedH)
            var currentSize: CGSize = self.window.contentLayoutRect.size
            currentSize.width = CGFloat(savedW)
            currentSize.height = CGFloat(savedH)
            self.window.setContentSize(currentSize)
            self.window.setFrameOrigin(NSPoint(x: CGFloat(savedX), y: CGFloat(savedY)))
        }
    }

    func applySettings() {
        QCSettingsManager.shared.logSettings(label: "applySettings")

        self.setRotation(self.position)
        self.captureLayer.connection?.isVideoMirrored = isMirrored
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
        QCSettingsManager.shared.setFrameProperties(
            x: Float(self.window.frame.minX),
            y: Float(self.window.frame.minY),
            width: Float(self.window.frame.width),
            height: Float(self.window.frame.height)
        )
        QCSettingsManager.shared.saveSettings()
    }

    @IBAction func clearSettings(_ sender: NSMenuItem) {
        QCSettingsManager.shared.clearSettings()
    }

    // MARK: - Display Actions
    @IBAction func mirrorHorizontally(_ sender: NSMenuItem) {
        NSLog("Mirror image menu item selected")
        isMirrored = !isMirrored
        self.applySettings()
    }

    func setRotation(_ position: Int) {
        switch position {
        case 1:
            if !isUpsideDown {
                self.captureLayer.connection?.videoOrientation =
                    AVCaptureVideoOrientation.landscapeLeft
            } else {
                self.captureLayer.connection?.videoOrientation =
                    AVCaptureVideoOrientation.landscapeRight
            }
            break
        case 2:
            if !isUpsideDown {
                self.captureLayer.connection?.videoOrientation =
                    AVCaptureVideoOrientation.portraitUpsideDown
            } else {
                self.captureLayer.connection?.videoOrientation = AVCaptureVideoOrientation.portrait
            }
            break
        case 3:
            if !isUpsideDown {
                self.captureLayer.connection?.videoOrientation =
                    AVCaptureVideoOrientation.landscapeRight
            } else {
                self.captureLayer.connection?.videoOrientation =
                    AVCaptureVideoOrientation.landscapeLeft
            }
            break
        case 0:
            if !isUpsideDown {
                self.captureLayer.connection?.videoOrientation = AVCaptureVideoOrientation.portrait
            } else {
                self.captureLayer.connection?.videoOrientation =
                    AVCaptureVideoOrientation.portraitUpsideDown
            }
            break
        default: break
        }
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

    @IBAction func saveImage(_ sender: NSMenuItem) {
        if self.window.styleMask.contains(.fullScreen) {
            NSLog("Save is not supported as window is full screen")
            return
        }

        if captureSession != nil {
            if #available(OSX 10.12, *) {
                // turn borderless on, capture image, return border to previous state
                let borderlessState: Bool = self.isBorderless
                if borderlessState == false {
                    NSLog("Removing border")
                    self.removeBorder()
                }

                /* Pause the RunLoop for 0.1 sec to let the window repaint after removing the border - I'm not a fan of this approach
                   but can't find another way to listen to an event for the window being updated. PRs welcome :) */
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))

                let cgImage: CGImage? = CGWindowListCreateImage(
                    CGRect.null, .optionIncludingWindow, CGWindowID(self.window.windowNumber),
                    [.boundsIgnoreFraming, .bestResolution])

                if borderlessState == false {
                    self.addBorder()
                }

                DispatchQueue.main.async {
                    let now: Date = Date()
                    let dateFormatter: DateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd"
                    let date: String = dateFormatter.string(from: now)
                    dateFormatter.dateFormat = "h.mm.ss a"
                    let time: String = dateFormatter.string(from: now)

                    let panel: NSSavePanel = NSSavePanel()
                    panel.nameFieldStringValue = String(
                        format: "Net Camera Image %@ at %@.png", date, time)
                    panel.beginSheetModal(for: self.window) {
                        (result: NSApplication.ModalResponse) in
                        if result == NSApplication.ModalResponse.OK {
                            NSLog(panel.url!.absoluteString)
                            let destination: CGImageDestination? = CGImageDestinationCreateWithURL(
                                panel.url! as CFURL, UTType.png.identifier as CFString, 1, nil)
                            if destination == nil {
                                NSLog(
                                    "Could not write file - destination returned from CGImageDestinationCreateWithURL was nil"
                                )
                                self.errorMessage(
                                    message:
                                        "Unfortunately, the image could not be saved to this location."
                                )
                            } else {
                                CGImageDestinationAddImage(destination!, cgImage!, nil)
                                CGImageDestinationFinalize(destination!)
                            }
                        }
                    }
                }
            } else {
                let popup: NSAlert = NSAlert()
                popup.messageText =
                    "Unfortunately, saving images is only supported in Mac OSX 10.12 (Sierra) and higher."
                popup.runModal()
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

    // MARK: - Application Lifecycle
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        detectVideoDevices()
        startCaptureWithVideoDevice(defaultDevice: defaultDeviceIndex)
        usb.delegate = self
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
