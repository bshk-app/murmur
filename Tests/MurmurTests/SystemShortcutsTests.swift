import Carbon.HIToolbox
import KeyboardShortcuts
import XCTest
@testable import Murmur

final class SystemShortcutsTests: XCTestCase {
    private let controlOptionSpace = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option])

    /// macOS hands its shortcuts out as Carbon key code + Carbon modifiers;
    /// they have to compare equal to the same chord built the library's way.
    func testACarbonEntryMatchesTheSameChordBuiltFromModifierFlags() {
        let fromSystem = KeyboardShortcuts.Shortcut(carbonKeyCode: kVK_Space, carbonModifiers: controlKey | optionKey)
        XCTAssertEqual(fromSystem, controlOptionSpace)
    }

    func testNoClashWhenMacOSDoesNotUseTheChord() {
        let spotlight = KeyboardShortcuts.Shortcut(.space, modifiers: [.command])
        XCTAssertNil(SystemShortcuts.clash(for: controlOptionSpace, among: [spotlight]))
        XCTAssertNil(SystemShortcuts.clash(for: nil, among: [controlOptionSpace]))
    }

    /// The case behind the bubble at the cursor: the old default, with the
    /// layout switch switched on as it is out of the box.
    func testTheOldDefaultIsALayoutSwitch() {
        XCTAssertEqual(SystemShortcuts.clash(for: controlOptionSpace, among: [controlOptionSpace]), .inputSource)
        let controlSpace = KeyboardShortcuts.Shortcut(.space, modifiers: [.control])
        XCTAssertEqual(SystemShortcuts.clash(for: controlSpace, among: [controlSpace]), .inputSource)
    }

    func testAnyOtherTakenChordIsReportedWithoutGuessingWhatItDoes() {
        let screenshot = KeyboardShortcuts.Shortcut(.three, modifiers: [.command, .shift])
        XCTAssertEqual(SystemShortcuts.clash(for: screenshot, among: [screenshot]), .other)
    }

    /// Fresh installs must not start out on a chord macOS switches layouts with.
    func testTheDefaultIsNotAMacOSLayoutSwitch() throws {
        let fallback = try XCTUnwrap(KeyboardShortcuts.Name.dictate.defaultShortcut)
        XCTAssertFalse(SystemShortcuts.inputSourceDefaults.contains(fallback))
        XCTAssertEqual(fallback, KeyboardShortcuts.Shortcut(.space, modifiers: [.option]))
    }
}
