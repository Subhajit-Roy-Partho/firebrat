import XCTest

@MainActor final class FirebratNativeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func testLibraryDeleteConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["-conversion.mode", "offline"]
        app.launchEnvironment["FIREBRAT_TEST_ARCHIVE_NAME"] = "native-package.tar.gz"
        app.launch(); app.buttons["Add"].tap(); app.buttons["Import test package"].tap()
        let remove = app.buttons["delete-book-native-import"]
        XCTAssertTrue(remove.waitForExistence(timeout: 20)); remove.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        let confirmation = XCTAttachment(screenshot: app.screenshot()); confirmation.lifetime = .keepAlways; add(confirmation)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(remove.exists)
        remove.tap(); app.buttons["Delete"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: remove)
        waitForExpectations(timeout: 10)
    }

    func testRemoveGeneratedFixtureBooks() throws {
        guard let raw = ProcessInfo.processInfo.environment["FIREBRAT_CLEANUP_IDS"], !raw.isEmpty else {
            throw XCTSkip("Explicit IDs required for device fixture cleanup")
        }
        var remaining = Set(raw.split(separator: ",").map { "delete-book-" + String($0) })
        let app = XCUIApplication(); app.launchArguments = ["-conversion.mode", "offline"]; app.launch()
        var misses = 0
        while !remaining.isEmpty {
            let candidates = app.buttons.matching(NSPredicate(format: "identifier IN %@", Array(remaining)))
            if let remove = candidates.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                let id = remove.identifier; remove.tap()
                XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5)); app.buttons["Delete"].tap()
                expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons[id])
                waitForExpectations(timeout: 10)
                remaining.remove(id); misses = 0
            } else {
                misses += 1
                XCTAssertLessThan(misses, 30, "Could not find the remaining explicitly selected fixture rows")
                if misses < 15 { app.swipeUp() } else { app.swipeDown() }
            }
        }
        let cleaned = XCTAttachment(screenshot: app.screenshot()); cleaned.lifetime = .keepAlways; add(cleaned)
    }

    func testOfflineLibraryAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-conversion.mode", "offline"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Checking server…"].exists)
        app.buttons["Add"].tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conversion"].exists)
        app.buttons["Done"].tap()
    }
    func testIllustratedLocalConversionAndReader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-local.compiler", "verbatim", "-conversion.mode", "local", "-conversion.contentMode", "illustrated", "-voice.engine", "apple"]
        app.launchEnvironment["FIREBRAT_TEST_PDF_NAME"] = "native-illustrated.pdf"
        app.launch()
        app.buttons["Add"].tap()
        app.buttons["Convert a book"].tap()
        XCTAssertTrue(app.buttons["Convert test PDF"].waitForExistence(timeout: 5))
        app.buttons["Convert test PDF"].tap()
        XCTAssertTrue(app.staticTexts["Converted offline — open the book in your library."].waitForExistence(timeout: 150))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["native-illustrated"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10))
        app.buttons["Pause"].tap()
        app.buttons["Source PDF"].tap()
        XCTAssertTrue(app.navigationBars["Source page"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testScannedPDFOfflineOCR() {
        let app = XCUIApplication()
        app.launchArguments = ["-local.compiler", "verbatim", "-conversion.mode", "local", "-conversion.contentMode", "illustrated", "-voice.engine", "apple"]
        app.launchEnvironment["FIREBRAT_TEST_PDF_NAME"] = "native-scanned.pdf"
        app.launch()
        app.buttons["Add"].tap(); app.buttons["Convert a book"].tap()
        app.buttons["Convert test PDF"].tap()
        XCTAssertTrue(app.staticTexts["Converted offline — open the book in your library."].waitForExistence(timeout: 150))
    }
    func testNestedPackageImport() {
        let app = XCUIApplication()
        app.launchArguments = ["-conversion.mode", "offline"]
        app.launchEnvironment["FIREBRAT_TEST_ARCHIVE_NAME"] = "native-package.tar.gz"
        app.launch()
        app.buttons["Add"].tap(); app.buttons["Import test package"].tap()
        XCTAssertTrue(app.staticTexts["Imported archive fixture"].waitForExistence(timeout: 20))
        app.staticTexts["Imported archive fixture"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
    }
    func testNovelLocalConversion() {
        let app = XCUIApplication()
        app.launchArguments = ["-local.compiler", "verbatim", "-conversion.mode", "local", "-conversion.contentMode", "novel", "-voice.engine", "apple"]
        app.launchEnvironment["FIREBRAT_TEST_PDF_NAME"] = "native-novel.pdf"
        app.launch()
        app.buttons["Add"].tap()
        app.buttons["Convert a book"].tap()
        app.buttons["Convert test PDF"].tap()
        XCTAssertTrue(app.staticTexts["Converted offline — open the book in your library."].waitForExistence(timeout: 150))
    }
    func testKokoroNovelConversion() {
        let app = XCUIApplication()
        app.launchArguments = ["-local.compiler", "verbatim", "-conversion.mode", "local", "-conversion.contentMode", "novel", "-voice.engine", "kokoro", "-kokoro.narrator", "Bella", "-kokoro.male", "Michael", "-kokoro.female", "Sarah"]
        app.launchEnvironment["FIREBRAT_TEST_PDF_NAME"] = "native-novel.pdf"
        app.launch()
        app.buttons["Add"].tap(); app.buttons["Convert a book"].tap()
        app.buttons["Convert test PDF"].tap()
        XCTAssertTrue(app.staticTexts["Converted offline — open the book in your library."].waitForExistence(timeout: 300))
    }

    func testSafariPWA() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(safari.staticTexts["Your books"].waitForExistence(timeout: 30))
        XCTAssertTrue(safari.links["Documentation"].exists)
        let read = safari.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20)); read.tap()
        XCTAssertTrue(safari.buttons["Source PDF"].waitForExistence(timeout: 20))
        let illustration = safari.buttons["Expand illustration"]
        XCTAssertTrue(illustration.waitForExistence(timeout: 20)); illustration.tap()
        XCTAssertTrue(safari.webViews.buttons["Close"].firstMatch.waitForExistence(timeout: 5))
        safari.webViews.buttons["Close"].firstMatch.tap()
        let narration = safari.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "The Lantern Circuit.")).firstMatch
        XCTAssertTrue(narration.waitForExistence(timeout: 10)); narration.tap()
        let pause = safari.buttons.matching(NSPredicate(format: "label MATCHES[c] %@", "pause")).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10), safari.debugDescription)
        pause.tap()
        print("SAFARI_STATE", safari.debugDescription)
        let attachment = XCTAttachment(screenshot: safari.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
    }

    private func convertWithModel(_ model: String, metal: Bool = false) {
        let app = XCUIApplication()
        app.launchArguments = ["-conversion.mode", "local", "-conversion.contentMode", "illustrated", "-voice.engine", "kokoro", "-local.compiler", "llm", "-local.model", model, "-local.metal", metal ? "YES" : "NO"]
        app.launchEnvironment["FIREBRAT_TEST_PDF_NAME"] = "native-illustrated.pdf"
        app.launch(); app.buttons["Add"].tap(); app.buttons["Convert a book"].tap()
        app.buttons["Convert test PDF"].tap()
        let finished = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", "Converted offline — open the book in your library.", "Conversion failed")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 600))
        XCTAssertTrue(app.staticTexts["Converted offline — open the book in your library."].exists, app.debugDescription)
    }
    func testQwenSmallLocalConversion() { convertWithModel("qwen3-0.6b") }
    func testQwenSmallRequestedMetalConversion() { convertWithModel("qwen3-0.6b", metal: true) }
    func testQwenBalancedLocalConversion() { convertWithModel("qwen3-1.7b") }
    func testGemmaLocalConversion() { convertWithModel("gemma-3-1b") }

    func testKokoroAllVoicesAndCasting() {
        let app = XCUIApplication()
        app.launchArguments = ["-local.compiler", "verbatim", "-conversion.mode", "local", "-conversion.contentMode", "novel", "-voice.engine", "kokoro", "-kokoro.narrator", "Bella", "-kokoro.male", "Adam", "-kokoro.female", "Default"]
        app.launchEnvironment["FIREBRAT_TEST_PDF_NAME"] = "native-voices.pdf"
        app.launch(); app.buttons["Add"].tap(); app.buttons["Convert a book"].tap()
        app.buttons["Convert test PDF"].tap()
        XCTAssertTrue(app.staticTexts["Converted offline — open the book in your library."].waitForExistence(timeout: 180))
    }

    func testServerDownloadAndReader() {
        let app = XCUIApplication()
        app.launchArguments = ["-conversion.mode", "server", "-conversion.cloudServerUrl", "http://127.0.0.1:8765"]
        app.launch()
        for _ in 0..<25 {
            if app.buttons["download-server-fixture"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["download-server-fixture"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["download-server-fixture"].tap()
        let localBook = app.buttons["local-book-server-fixture"]
        for _ in 0..<25 {
            if localBook.exists { break }
            app.swipeDown()
        }
        XCTAssertTrue(localBook.waitForExistence(timeout: 20), app.debugDescription)
        localBook.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10))
    }

}
