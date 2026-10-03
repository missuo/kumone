import XCTest
import UIKit

final class KumoneIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLegacyNavigationLaunchPushAndBack() throws {
        try verifyNavigation(legacy: true)
    }

    @MainActor
    func testModernNavigationLaunchPushAndBack() throws {
        try verifyNavigation(legacy: false)
    }

    @MainActor
    func testLegacyNestedAlbumArtistNavigation() throws {
        try verifyNestedNavigation(legacy: true)
    }

    @MainActor
    func testModernNestedAlbumArtistNavigation() throws {
        try verifyNestedNavigation(legacy: false)
    }

    @MainActor
    func testModernSearchAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-disable-updates"]
        app.launch()
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 15))
            app.tabBars.buttons["我的"].tap()
        }
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 15))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        if UIDevice.current.userInterfaceIdiom == .phone {
            app.tabBars.buttons["搜索"].tap()
        } else {
            app.buttons["搜索"].tap()
        }
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        search.typeText("周杰伦\n")
        let artists = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "destination.artist("))
        XCTAssertTrue(artists.firstMatch.waitForExistence(timeout: 40))
        var artist = artists.allElementsBoundByIndex.first(where: { $0.isHittable })
        for _ in 0..<5 where artist == nil {
            app.swipeUp()
            artist = artists.allElementsBoundByIndex.first(where: { $0.isHittable })
        }
        try XCTUnwrap(artist).tap()
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func verifyNestedNavigation(legacy: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-disable-updates"]
        if legacy { app.launchArguments.append("--test-legacy-navigation") }
        app.launch()
        let albums = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "destination.album("))
        XCTAssertTrue(app.staticTexts["推荐歌单"].waitForExistence(timeout: 40))
        var album: XCUIElement?
        for _ in 0..<6 {
            album = albums.allElementsBoundByIndex.first(where: { $0.isHittable })
            if album != nil { break }
            app.swipeUp()
        }
        try XCTUnwrap(album).tap()
        let artists = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "destination.artist("))
        XCTAssertTrue(artists.firstMatch.waitForExistence(timeout: 30))
        try XCTUnwrap(artists.allElementsBoundByIndex.first(where: { $0.isHittable })).tap()
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(artists.firstMatch.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(albums.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    private func verifyNavigation(legacy: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--test-disable-updates"]
        if legacy { app.launchArguments.append("--test-legacy-navigation") }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))

        // Exercise a real playlist route, not just app launch. Home needs network.
        let links = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "destination.playlist(")
        )
        XCTAssertTrue(links.firstMatch.waitForExistence(timeout: 40))
        let link = try XCTUnwrap(links.allElementsBoundByIndex.first(where: { $0.isHittable }))
        let routeID = link.identifier
        link.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "播放全部")).firstMatch.waitForExistence(timeout: 30))
        let back = app.navigationBars.buttons.matching(
            NSPredicate(format: "label IN %@", ["推荐", "Back", "返回"])
        ).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15))
        back.tap()
        XCTAssertTrue(app.buttons.matching(identifier: routeID).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(identifier: routeID).allElementsBoundByIndex.contains(where: { $0.isHittable }))
        XCTAssertEqual(app.state, .runningForeground)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = legacy ? "Legacy navigation after back" : "Modern navigation after back"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
