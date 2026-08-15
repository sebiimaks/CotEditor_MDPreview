//
//  UITests.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2018-02-13.
//
//  ---------------------------------------------------------------------------
//
//  © 2018-2026 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest

@MainActor final class UITests: XCTestCase {
    
    override func setUp() async throws {
        
        try await super.setUp()
        
        // In UI tests it is usually best to stop immediately when a failure occurs.
        self.continueAfterFailure = false
    }
    
    
    func testTyping() {
        
        let app = XCUIApplication()
        app.launch()
        
        // open a new document
        let menuBarsQuery = app.menuBars
        menuBarsQuery.menuBarItems["File"].click()
        menuBarsQuery.menuItems["New Window"].click()
        
        // type some words
        let documentWindow = app.windows.firstMatch
        let textView = documentWindow.textViews.firstMatch
        _ = textView.waitForExistence(timeout: 5)
        textView.typeText("Test.\r")
        XCTAssertEqual(textView.value as! String, "Test.\n")
        
        // wait a bit to let document autosave
        sleep(1)
        
        // delete entire words
        for _ in 1...6 {
            textView.typeKey(.delete, modifierFlags: [])
        }
        
        // close window without saving
        let windowCount = app.windows.count
        documentWindow.buttons[XCUIIdentifierCloseWindow].click()
        let deleteButton = documentWindow.sheets.firstMatch.children(matching: .button)["Delete"]
        if deleteButton.waitForExistence(timeout: 1) {
            // it actually depends on user settings and iCloud availability if save sheet appears...
            deleteButton.click()
        }
        let windowClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.windows.count == windowCount - 1 },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [windowClosed], timeout: 5), .completed)
    }
    
    
    func testSettingsWindow() {
        
        let app = XCUIApplication()
        app.launch()
        
        // open the Settings window
        let menuBarsQuery = app.menuBars
        menuBarsQuery.menuBarItems["CotEditor"].click()
        menuBarsQuery.menuItems["Settings…"].click()
        
        // open all panes
        app.buttons["General"].firstMatch.click()
        app.buttons["Appearance"].firstMatch.click()
        app.buttons["Window"].firstMatch.click()
        app.buttons["Edit"].firstMatch.click()
        app.buttons["Mode"].firstMatch.click()
        app.buttons["Format"].firstMatch.click()
        app.buttons["Snippets"].firstMatch.click()
        app.buttons["Shortcuts"].firstMatch.click()
        app.buttons["Donation"].firstMatch.click()
    }
    
    
    func testMarkdownPreview() {
        
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-noDocumentOnLaunchOption", "2"]
        app.launch()
        
        // open a new document
        let menuBarsQuery = app.menuBars
        menuBarsQuery.menuBarItems["File"].click()
        menuBarsQuery.menuItems["New Window"].click()
        
        let documentWindow = app.windows.firstMatch
        XCTAssertEqual(app.windows.count, 1)
        let syntaxPopUpButton = documentWindow.popUpButtons["syntaxPopUpButton"]
        XCTAssert(syntaxPopUpButton.waitForExistence(timeout: 5))
        let previewButton = documentWindow.descendants(matching: .any)
            .matching(identifier: "markdownPreviewButton")
            .firstMatch
        XCTAssertFalse(previewButton.exists)
        
        // select Markdown to reveal the preview toggle
        syntaxPopUpButton.click()
        documentWindow.menuItems["Markdown"].firstMatch.click()
        
        XCTAssertEqual(syntaxPopUpButton.value as? String, "Markdown")
        XCTAssert(previewButton.waitForExistence(timeout: 2), app.debugDescription)
        let editor = documentWindow.textViews.firstMatch
        XCTAssert(editor.waitForExistence(timeout: 2))
        editor.click()
        editor.typeText("# Rendered preview")
        previewButton.click()
        
        let previewWebView = documentWindow.descendants(matching: .any)
            .matching(identifier: "MarkdownPreviewWebView")
            .firstMatch
        XCTAssert(previewWebView.waitForExistence(timeout: 5))
        let renderedHeading = documentWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Rendered preview"))
            .firstMatch
        XCTAssert(renderedHeading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssert(editor.exists)
        
        // render subsequent edits without closing the preview
        editor.click()
        editor.typeText("\n\nLive update")
        let liveUpdate = documentWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Live update"))
            .firstMatch
        XCTAssert(liveUpdate.waitForExistence(timeout: 5), app.debugDescription)
        
        // changing away from Markdown closes the preview and hides the toggle
        syntaxPopUpButton.click()
        documentWindow.menuItems["None"].firstMatch.click()
        XCTAssertEqual(syntaxPopUpButton.value as? String, "None")
        XCTAssert(previewWebView.waitForNonExistence(timeout: 2))
        XCTAssert(previewButton.waitForNonExistence(timeout: 2))
        
        // returning to Markdown reveals an inactive toggle
        syntaxPopUpButton.click()
        documentWindow.menuItems["Markdown"].firstMatch.click()
        XCTAssertEqual(syntaxPopUpButton.value as? String, "Markdown")
        XCTAssert(previewButton.waitForExistence(timeout: 2))
        XCTAssertFalse(previewWebView.exists)
        
        // close window without saving
        documentWindow.buttons[XCUIIdentifierCloseWindow].click()
        if documentWindow.sheets.count > 0 {
            documentWindow.sheets.firstMatch.children(matching: .button)["Delete"].click()
        }
    }
    
    
    func testLaunchPerformance() throws {
        
        // This measures how long it takes to launch your application.
        self.measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
