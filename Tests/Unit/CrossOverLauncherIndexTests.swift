import XCTest
@testable import macos_dock_cc_v2

/// A CrossOver program started outside its launcher (qBittorrent from a magnet link) has no
/// bundle; it is matched to the launcher by exe name.
final class CrossOverLauncherIndexTests: XCTestCase {
    private let qbit = "com.codeweavers.CrossOverHelper.B7749EA587E237E6.44E535C5E7CD553E"
    private let firefox = "com.codeweavers.CrossOverHelper.B7749EA587E237E6.763F7F1AEC350CD1"

    func testProgramKeyIsTheExeBaseNameOnly() {
        XCTAssertEqual(CrossOverLauncherIndex.programKey(processName: "qbittorrent.exe", executablePath: nil),
                       "qbittorrent")
        XCTAssertEqual(CrossOverLauncherIndex.programKey(processName: nil,
                                                         executablePath: "/var/folders/T/winetemp-1/QBitTorrent.EXE"),
                       "qbittorrent")
        XCTAssertNil(CrossOverLauncherIndex.programKey(processName: "qBittorrent", executablePath: "/Applications/x"))
    }

    func testIndexMatchesMenuNameBundleNameAndFileName() {
        let index = CrossOverLauncherIndex.index(launcherPlists: [
            ["CFBundleIdentifier": qbit, "CFBundleName": "qbittorrent", "CXOriginalMenuName": "qbittorrent",
             "fileName": "qbittorrent"],
            ["CFBundleIdentifier": firefox, "CFBundleName": "Firefox", "fileName": "Firefox"],
            ["CFBundleIdentifier": "org.mozilla.firefox", "CFBundleName": "Other"]
        ])
        XCTAssertEqual(index["qbittorrent"], qbit)
        XCTAssertEqual(index["firefox"], firefox)
        XCTAssertNil(index["other"], "only CrossOver launchers are indexed")
    }

    func testANameTwoLaunchersClaimIsDropped() {
        let index = CrossOverLauncherIndex.index(launcherPlists: [
            ["CFBundleIdentifier": qbit, "CFBundleName": "tool"],
            ["CFBundleIdentifier": firefox, "CFBundleName": "Tool"]
        ])
        XCTAssertNil(index["tool"])
    }
}
