//
//  MarkdownPreviewControllerTests.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by Codex on 2026-08-15.
//
//  ---------------------------------------------------------------------------
//
//  © 2026 1024jp
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

import AppKit
import Testing
@testable import CotEditor

@MainActor struct MarkdownPreviewControllerTests {
    
    @Test func togglingPreviewPreservesEditorControllerAndSplitState() throws {
        
        let document = Document()
        document.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: document.textStorage.length),
            with: "# Preview\n\nBody"
        )
        
        let contentViewController = ContentViewController(document: document)
        contentViewController.loadViewIfNeeded()
        
        let editorViewController = try #require(contentViewController.documentViewController)
        let numberOfEditorSplits = editorViewController.splitViewItems.count
        
        contentViewController.setMarkdownPreviewVisible(true)
        
        #expect(contentViewController.showsMarkdownPreview)
        #expect(contentViewController.documentViewController === editorViewController)
        #expect(editorViewController.splitViewItems.count == numberOfEditorSplits)
        
        contentViewController.setMarkdownPreviewVisible(false)
        
        #expect(!contentViewController.showsMarkdownPreview)
        #expect(contentViewController.documentViewController === editorViewController)
        #expect(editorViewController.splitViewItems.count == numberOfEditorSplits)
    }
    
    
    @Test func changingDocumentResetsPreviewState() throws {
        
        let firstDocument = Document()
        let contentViewController = ContentViewController(document: firstDocument)
        contentViewController.loadViewIfNeeded()
        
        let firstEditorViewController = try #require(contentViewController.documentViewController)
        contentViewController.setMarkdownPreviewVisible(true)
        #expect(contentViewController.showsMarkdownPreview)
        
        contentViewController.document = Document()
        
        #expect(!contentViewController.showsMarkdownPreview)
        #expect(contentViewController.documentViewController !== firstEditorViewController)
    }
}
