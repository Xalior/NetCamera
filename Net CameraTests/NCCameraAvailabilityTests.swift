import AVFoundation
import XCTest

// MARK: - Camera availability

/// What the app decides about the picture, from the permission the system
/// reports and the number of cameras found.
///
/// The whole point of deciding it this way is that it can be checked with no
/// camera, no window and no permission of any kind: the two inputs are values,
/// so every combination of them — including the ones a developer's own Mac can
/// never reach, such as a refusal, and the ones an App Store reviewer meets on
/// their first launch — is testable here.
final class NCCameraAvailabilityTests: XCTestCase {
    // MARK: - Deciding the state

    func testPermissionAndACameraIsThePictureShowing() {
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .authorized, deviceCount: 1), .available)
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .authorized, deviceCount: 7), .available)
    }

    func testPermissionAndNoCameraIsNotAPermissionProblem() {
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .authorized, deviceCount: 0), .noDevice)
    }

    /// The reviewer's first launch on a Mac that has a camera: nobody has been
    /// asked anything yet, and the question is worth asking.
    func testAnUndecidedPermissionWithACameraIsItsOwnState() {
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .notDetermined, deviceCount: 1),
            .undetermined)
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .notDetermined, deviceCount: 3),
            .undetermined)
    }

    /// The reviewer's first launch in a virtual machine, and the one case here
    /// that was measured rather than reasoned about. With no camera attached,
    /// `AVCaptureDevice.requestAccess(for: .video)` puts nothing on screen,
    /// answers "no" immediately and leaves the recorded permission undecided —
    /// macOS will not ask about a camera that does not exist. Calling that
    /// state "waiting for camera access" would be a wait that never ends, so
    /// the honest answer is the hardware one.
    func testAnUndecidedPermissionWithNoCameraIsSimplyNoCamera() {
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .notDetermined, deviceCount: 0), .noDevice)
    }

    /// A decided refusal is answered before hardware. Telling somebody who
    /// refused access that no camera is connected sends them looking in the
    /// wrong place, and on a Mac where a refusal also hides the cameras it
    /// would be the only thing they were ever told.
    func testARefusalIsReportedEvenWhenCamerasWereFound() {
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .denied, deviceCount: 0), .denied)
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .denied, deviceCount: 2), .denied)
    }

    func testAPolicyRestrictionIsNotTheSameAsARefusal() {
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .restricted, deviceCount: 0), .restricted)
        XCTAssertEqual(
            NCCameraAvailability.resolve(authorization: .restricted, deviceCount: 2), .restricted)
    }

    // MARK: - Only one state has a picture

    func testExactlyOneStateMeansThereIsAPicture() {
        XCTAssertTrue(NCCameraAvailability.available.hasPicture)
        for state: NCCameraAvailability in [.undetermined, .denied, .restricted, .noDevice] {
            XCTAssertFalse(state.hasPicture, "\(state) has no picture to show")
        }
    }

    // MARK: - What the user is told

    /// Every state that has no picture and is not waiting for an answer says
    /// why. A state that fell through with nothing to say would leave the user
    /// with a window that explains nothing, which is the whole defect this
    /// exists to close.
    func testEveryStoppedStateExplainsItself() {
        for state: NCCameraAvailability in [.denied, .restricted, .noDevice] {
            let explanation: String? = state.explanation
            XCTAssertNotNil(explanation, "\(state) must say what is wrong")
            XCTAssertFalse(
                explanation?.isEmpty ?? true, "\(state)'s explanation must not be empty")
        }
    }

    /// Nothing is said in the two states where saying something would be
    /// wrong: there is nothing to explain when the picture is showing, and the
    /// system's own permission request is on screen while the answer is
    /// undecided.
    func testNothingIsSaidWhenThereIsNothingToSay() {
        XCTAssertNil(NCCameraAvailability.available.explanation)
        XCTAssertNil(NCCameraAvailability.undetermined.explanation)
    }

    // MARK: - The route out

    /// Only a refusal the user made themselves can be undone in settings. A
    /// restriction is set by a configuration profile or by parental controls,
    /// so sending them to a switch they cannot operate would be a dead end
    /// dressed up as help.
    func testOnlyARefusalIsWorthSendingToSettings() {
        XCTAssertTrue(NCCameraAvailability.denied.offersSystemSettings)
        for state: NCCameraAvailability in [.available, .undetermined, .restricted, .noDevice] {
            XCTAssertFalse(state.offersSystemSettings, "\(state) has nothing to offer in settings")
        }
    }

    func testTheSettingsURLIsTheCameraPrivacyPane() {
        let url: URL? = NCCameraAvailability.systemSettingsURL
        XCTAssertNotNil(url, "the one route out of a refusal must be a usable URL")
        XCTAssertEqual(url?.scheme, "x-apple.systempreferences")
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    // MARK: - The window title stays the diagnostic

    /// The nib bakes the bare string "Net Camera" into the window, so a title
    /// carrying a bracketed detail is the only evidence from outside that the
    /// real delegate is running. A no-picture state that had no detail to offer
    /// would leave the title as the nib wrote it, and the app would then be
    /// indistinguishable from one whose delegate never started at all.
    func testEveryStateHasSomethingToPutInTheWindowTitle() {
        for state: NCCameraAvailability in [
            .available, .undetermined, .denied, .restricted, .noDevice,
        ] {
            XCTAssertFalse(
                state.windowTitleDetail.isEmpty, "\(state) must name itself in the window title")
        }
    }

    /// And the details differ, so the title says which state the app is in
    /// rather than merely that it is in one.
    func testTheNoPictureStatesDoNotShareATitleDetail() {
        let details: [String] = [
            NCCameraAvailability.undetermined.windowTitleDetail,
            NCCameraAvailability.denied.windowTitleDetail,
            NCCameraAvailability.restricted.windowTitleDetail,
            NCCameraAvailability.noDevice.windowTitleDetail,
        ]
        XCTAssertEqual(Set(details).count, details.count)
    }
}
