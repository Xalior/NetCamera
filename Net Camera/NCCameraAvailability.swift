import AVFoundation

// MARK: - Camera availability

/// Whether there is a picture to show, and when there is not, why not.
///
/// Having no picture is an ordinary state this app sits in and recovers from,
/// never a reason to stop. Permission that has not been granted and a Mac with
/// no camera attached are two roads into that state; a camera unplugged while
/// the app is running is a third. All of them are temporary, so the app keeps
/// its window, its menus and its web server, says plainly what is wrong, and
/// starts showing the picture the moment the reason goes away.
///
/// The value is decided from two facts and nothing else — what the system says
/// about permission, and how many capture devices were found — which is what
/// lets it be worked out, and asserted, with no camera and no running
/// application.
enum NCCameraAvailability: Equatable {
    /// Permission is granted and there is a camera to show.
    case available
    /// Permission has not been decided yet: either it has never been asked for,
    /// or the answer to the request has not come back.
    case undetermined
    /// The user refused access. This is the one state that has somewhere useful
    /// to send them.
    case denied
    /// Policy forbids camera access — a configuration profile, or parental
    /// controls. The user cannot grant it, so they must not be told to try.
    case restricted
    /// Permission is granted and no camera is attached.
    case noDevice

    // MARK: - Deciding

    /// Works out the state from the permission the system reports and the
    /// number of capture devices found.
    ///
    /// A decided refusal is answered before hardware, because someone who has
    /// been refused has a problem they can act on, and telling them "no camera
    /// is connected" sends them looking in the wrong place.
    ///
    /// An *undecided* permission with no camera is the other way round, and
    /// this was measured rather than assumed: on a Mac with no camera at all,
    /// `AVCaptureDevice.requestAccess(for: .video)` shows the user nothing,
    /// answers "no" straight away, and leaves the recorded permission
    /// undecided. macOS will not ask about a camera that does not exist. So
    /// with nothing attached, no camera is the whole truth — and it stays the
    /// truth until one is plugged in, at which point the question becomes
    /// worth asking and is asked.
    static func resolve(
        authorization: AVAuthorizationStatus, deviceCount: Int
    ) -> NCCameraAvailability {
        switch authorization {
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            return 0 < deviceCount ? .available : .noDevice
        case .notDetermined:
            return 0 < deviceCount ? .undetermined : .noDevice
        @unknown default:
            // A status this build does not know about is treated as a refusal.
            // Of the states available, that is the one whose message names
            // permission as the obstacle and offers the settings that control
            // it, which is the most useful thing to say about any future way of
            // being told no.
            return .denied
        }
    }

    // MARK: - What the state means

    /// Whether the app has a picture to show.
    var hasPicture: Bool { self == .available }

    /// What belongs inside the brackets in the window's title.
    ///
    /// The nib bakes the bare string "Net Camera" into the window, so a title
    /// carrying a bracketed detail is the only evidence from outside that the
    /// real delegate is running: when the nib's class lookup fails, no delegate
    /// exists, nothing runs, and what is left on screen is a normal-looking
    /// window wearing that bare title. Every no-picture state therefore names
    /// itself in the same bracketed shape instead of letting the title fall
    /// back to the string the nib supplied.
    var windowTitleDetail: String {
        switch self {
        case .available:
            // The camera's own name is used instead, which no state here knows.
            return "camera"
        case .undetermined:
            return "waiting for camera access"
        case .denied:
            return "camera access denied"
        case .restricted:
            return "camera access not permitted"
        case .noDevice:
            return "no camera"
        }
    }

    /// What to tell the user about this state, or nil when there is nothing
    /// worth saying.
    ///
    /// Nothing is said while permission is undecided, because the system's own
    /// permission request is on screen at that moment and a second message
    /// behind it only gets in the way.
    var explanation: String? {
        switch self {
        case .available, .undetermined:
            return nil
        case .denied:
            return """
                Net Camera has not been allowed to use the camera, so there is \
                no picture to show. Open Privacy & Security settings, switch \
                Camera on for Net Camera, and the picture will appear.
                """
        case .restricted:
            return """
                Camera access is not permitted on this Mac. This is set by a \
                configuration profile or by parental controls, so it cannot be \
                changed from here.
                """
        case .noDevice:
            return """
                No camera is connected. Net Camera will show the picture as \
                soon as a camera is plugged in.
                """
        }
    }

    /// Whether sending the user to the camera privacy settings would help.
    /// Only a refusal the user made themselves can be undone there.
    var offersSystemSettings: Bool { self == .denied }

    /// The Privacy & Security pane, opened straight at its Camera section.
    ///
    /// A URL rather than a scripted trip through the Settings app, because this
    /// is the one route out of a refusal that works from inside the sandbox.
    static let systemSettingsURL: URL? = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
}
