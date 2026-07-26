import XCTest

// MARK: - Harness self-check

/// Proves the test harness itself executes tests.
///
/// A scheme whose `Testables` list is empty, or whose `BlueprintIdentifier`
/// names a target that no longer exists, makes `xcodebuild test` run nothing
/// at all and still exit zero. Exit status therefore cannot distinguish
/// "everything passed" from "nothing ran". `make check` asserts a non-zero
/// executed-test count for that reason, and this case is the floor of that
/// count: if it does not appear in the results, the harness is not wired up.
final class NCHarnessTests: XCTestCase {
    func testHarnessExecutesTests() {
        XCTAssertTrue(true, "The test harness ran a test.")
    }
}
