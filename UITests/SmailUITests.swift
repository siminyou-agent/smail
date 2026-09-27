import XCTest

final class SmailUITests: XCTestCase {
    private func waitForProgress(_ value: String, app: XCUIApplication) {
        let predicate = NSPredicate(format: "label == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.staticTexts["progress"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 3), .completed)
    }
    func testTenCardFlowDetailUndoAndSummary() {
        checkTenCardFlow(language: "zh-Hans")
    }
    func testEnglishTenCardFlowDetailUndoAndSummary() {
        checkTenCardFlow(language: "en")
    }
    private func checkTenCardFlow(language: String) {
        let chinese = language == "zh-Hans"
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "-appLanguage", language]; app.launch()
        XCTAssertTrue(app.buttons["useful"].waitForExistence(timeout: 10))
        app.buttons["mail-card"].tap()
        XCTAssertTrue(app.navigationBars[chinese ? "邮件正文" : "Email"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.links[chinese ? "阅读更多" : "Read more"].waitForExistence(timeout: 5))
        app.buttons[chinese ? "完成" : "Done"].tap()
        app.buttons["useful"].tap()
        waitForProgress("1 / 10", app: app)
        let undo = app.buttons["undo"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: undo)
        waitForExpectations(timeout: 5)
        undo.tap()
        waitForProgress("0 / 10", app: app)
        app.buttons["mail-card"].swipeLeft()
        waitForProgress("1 / 10", app: app)
        for count in 2...10 {
            app.buttons["useful"].tap()
            waitForProgress("\(count) / 10", app: app)
        }
        XCTAssertTrue(app.buttons["next-batch"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[chinese ? "有用 9 封  ·  没用 1 封" : "Useful: 9  ·  Not useful: 1"].exists)
        app.buttons["refresh-batch"].tap()
        waitForProgress("0 / 10", app: app)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.staticTexts[chinese ? "演示模式 · 不连接 Gmail" : "Demo mode · Not connected to Gmail"].waitForExistence(timeout: 3))
    }

    func testLanguageSwitchingPersistenceAndSystemDefault() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-language", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["useful"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Useful"].exists)
        app.buttons["useful"].tap()
        waitForProgress("1 / 10", app: app)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["language-picker"].tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["progress"].label, "1 / 10")
        XCTAssertTrue(app.staticTexts["有用"].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["useful"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["有用"].exists)
        app.buttons["settings"].tap()
        app.buttons["language-picker"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["mail-card"].tap()
        XCTAssertTrue(app.navigationBars["Email"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["settings"].tap()
        app.buttons["language-picker"].tap()
        app.buttons["System Default"].tap()
        app.terminate()

        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["useful"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["有用"].exists)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
    }
}
