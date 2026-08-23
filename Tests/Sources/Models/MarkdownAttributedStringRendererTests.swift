//
//  MarkdownAttributedStringRendererTests.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by Codex on 2026-08-22.
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

@MainActor struct MarkdownAttributedStringRendererTests {
    
    @Test func blockAndInlineStyles() throws {
        
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: """
            # Heading
            
            A *small* **strong** [link](https://example.com).
            """).attributedString
        let string = attributedString.string
        
        #expect(string == "Heading\nA small strong link.\n")
        
        let headingRange = try #require(string.range(of: "Heading")).nsRange(in: string)
        let bodyRange = try #require(string.range(of: "A ")).nsRange(in: string)
        let emphasisRange = try #require(string.range(of: "small")).nsRange(in: string)
        let strongRange = try #require(string.range(of: "strong")).nsRange(in: string)
        let linkRange = try #require(string.range(of: "link")).nsRange(in: string)
        let headingFont = try #require(attributedString.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont)
        let bodyFont = try #require(attributedString.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        let emphasisFont = try #require(attributedString.attribute(.font, at: emphasisRange.location, effectiveRange: nil) as? NSFont)
        let strongFont = try #require(attributedString.attribute(.font, at: strongRange.location, effectiveRange: nil) as? NSFont)
        
        #expect(headingFont.pointSize > bodyFont.pointSize)
        #expect(emphasisFont.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(strongFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(attributedString.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    }
    
    
    @Test func nativeBlockStructure() {
        
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: """
            > Quote
            
            3. First
            4. Second
            
            | A | B |
            |---|---|
            | 1 | 2 |
            """).attributedString
        
        #expect(attributedString.string.contains("│ Quote\n"))
        #expect(attributedString.string.contains("3. First\n4. Second\n"))
        #expect(attributedString.string.contains("A\tB\n1\t2\n"))
    }
    
    
    @Test func listMarkerAppearsOnlyOncePerItem() {
        
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: """
            - First paragraph
              
              Continuation
            - Second item
            """).attributedString
        
        #expect(attributedString.string.filter { $0 == "•" }.count == 2)
        #expect(attributedString.string.contains("Continuation"))
    }
    
    
    @Test func emptyListItemsRemainVisible() {
        
        let orderedString = MarkdownAttributedStringRenderer.render(markdown: "1. First\n2.\n3. Third").attributedString.string
        let unorderedString = MarkdownAttributedStringRenderer.render(markdown: "-\n- Second").attributedString.string
        
        #expect(orderedString.contains("1. First\n2. \n3. Third\n"))
        #expect(unorderedString.filter { $0 == "•" }.count == 2)
        #expect(unorderedString.contains("• \n• Second\n"))
    }
    
    
    @Test func nestedListRetainsEmptyParentMarker() throws {
        
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: "-\n  3. Nested").attributedString
        let paragraphStyles = attributedString.paragraphStyles
        
        #expect(attributedString.string == "• \n3. Nested\n")
        try #require(paragraphStyles.count == 2)
        #expect(paragraphStyles[0].firstLineHeadIndent == 0)
        #expect(paragraphStyles[0].headIndent == 24)
        #expect(paragraphStyles[1].firstLineHeadIndent == 24)
        #expect(paragraphStyles[1].headIndent == 48)
    }
    
    
    @Test func nestedListRetainsAllEmptyAncestors() {
        
        let string = MarkdownAttributedStringRenderer.render(markdown: """
            -
              1.
                 - Leaf
            - Sibling
            """).attributedString.string
        
        #expect(string == "• \n1. \n• Leaf\n• Sibling\n")
    }
    
    
    @Test func nestedListDoesNotRepeatVisibleParentMarker() {
        
        let string = MarkdownAttributedStringRenderer.render(markdown: """
            - Parent
              1. Child
            - Sibling
            """).attributedString.string
        
        #expect(string == "• Parent\n1. Child\n• Sibling\n")
    }
    
    
    @Test func tablePreservesEmptyCellsAndRows() {
        
        let separator = ["", ":--", ":--:", "--:", ""].joined(separator: "|")
        let markdown = ["| A |   | C |", separator, "|   | B |   |", "|   |   |   |", "| D | E | F |"]
            .joined(separator: "\n")
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: markdown).attributedString
        let string = attributedString.string
        
        #expect(string.contains("A\t\tC\n"))
        #expect(string.contains("\tB\t\n"))
        #expect(string.contains("\t\t\nD\tE\tF\n"))
        
        let range = NSRange(location: 0, length: attributedString.length)
        let paragraphStyle = attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(range.length > 0)
        #expect(paragraphStyle?.tabStops.map(\.alignment) == [.center, .right])
        #expect(paragraphStyle?.tabStops.map(\.location) == [240, 480])
    }
    
    
    @Test func tableUsesScrollableMinimumWidthWithoutWideningProse() {
        
        let tableRendering = MarkdownAttributedStringRenderer.render(markdown: """
            | A | B | C |
            |---|---|---|
            | 1 | 2 | 3 |
            """)
        let proseRendering = MarkdownAttributedStringRenderer.render(markdown: "Ordinary prose")
        
        #expect(tableRendering.minimumContentWidth == 480)
        #expect(proseRendering.minimumContentWidth == 0)
        #expect(MarkdownPreviewLayout.documentWidth(
            viewportWidth: 176,
            minimumContentWidth: tableRendering.minimumContentWidth,
            horizontalInset: 32
        ) == 544)
        #expect(MarkdownPreviewLayout.documentWidth(
            viewportWidth: 176,
            minimumContentWidth: proseRendering.minimumContentWidth,
            horizontalInset: 32
        ) == 176)
    }
    
    
    @Test func tableHeaderPreservesInlineFonts() throws {
        
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: """
            | *Emphasis* | `Code` |
            |---|---|
            | Value | Value |
            """).attributedString
        let string = attributedString.string
        let emphasisRange = try #require(string.range(of: "Emphasis")).nsRange(in: string)
        let codeRange = try #require(string.range(of: "Code")).nsRange(in: string)
        let emphasisFont = try #require(
            attributedString.attribute(.font, at: emphasisRange.location, effectiveRange: nil) as? NSFont
        )
        let codeFont = try #require(
            attributedString.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        )
        
        #expect(emphasisFont.fontDescriptor.symbolicTraits.contains([.bold, .italic]))
        #expect(codeFont.fontDescriptor.symbolicTraits.contains([.bold, .monoSpace]))
    }
    
    
    @Test func tableRetainsContainerDecoration() {
        
        let quotedTable = MarkdownAttributedStringRenderer.render(markdown: """
            > | A | B |
            > |---|---|
            > | 1 | 2 |
            """).attributedString.string
        
        #expect(quotedTable.contains("│ \nA\tB\n1\t2\n"))
    }
    
    
    @Test func unsafeContentRemainsText() throws {
        
        let attributedString = MarkdownAttributedStringRenderer.render(markdown: """
            <script>alert("unsafe")</script>
            
            [Unsafe](javascript:alert(1))
            """).attributedString
        let string = attributedString.string
        let unsafeRange = try #require(string.range(of: "Unsafe")).nsRange(in: string)
        
        #expect(string.contains("<script>alert(\"unsafe\")</script>"))
        #expect(attributedString.attribute(.link, at: unsafeRange.location, effectiveRange: nil) == nil)
    }
    
    
    @Test func externalLinkPolicy() throws {
        
        let httpsURL = try #require(URL(string: "https://example.com/path"))
        let httpURL = try #require(URL(string: "http://example.com"))
        let mailtoURL = try #require(URL(string: "mailto:person@example.com"))
        let scriptURL = try #require(URL(string: "javascript:alert(1)"))
        let dataURL = try #require(URL(string: "data:text/plain,unsafe"))
        let customURL = try #require(URL(string: "coteditor://preview"))
        let relativeURL = try #require(URL(string: "relative/path"))
        let hostlessURL = try #require(URL(string: "https:///path"))
        
        #expect(MarkdownAttributedStringRenderer.isAllowedExternalLink(httpsURL))
        #expect(MarkdownAttributedStringRenderer.isAllowedExternalLink(httpURL))
        #expect(!MarkdownAttributedStringRenderer.isAllowedExternalLink(mailtoURL))
        #expect(!MarkdownAttributedStringRenderer.isAllowedExternalLink(scriptURL))
        #expect(!MarkdownAttributedStringRenderer.isAllowedExternalLink(dataURL))
        #expect(!MarkdownAttributedStringRenderer.isAllowedExternalLink(customURL))
        #expect(!MarkdownAttributedStringRenderer.isAllowedExternalLink(relativeURL))
        #expect(!MarkdownAttributedStringRenderer.isAllowedExternalLink(hostlessURL))
    }
    
    
    @Test func imagesRemainAlternativeTextOnly() throws {
        
        let attributedString = MarkdownAttributedStringRenderer.render(
            markdown: "![Diagram](https://example.com/diagram.png)"
        ).attributedString
        let diagramRange = try #require(attributedString.string.range(of: "Diagram")).nsRange(in: attributedString.string)
        
        #expect(attributedString.attribute(.attachment, at: diagramRange.location, effectiveRange: nil) == nil)
        #expect(attributedString.attribute(.link, at: diagramRange.location, effectiveRange: nil) == nil)
    }
    
    
    @Test func renderingOwnsAnImmutableCopy() {
        
        let mutableString = NSMutableAttributedString(string: "Before")
        let rendering = MarkdownPreviewRendering(attributedString: mutableString)
        mutableString.mutableString.setString("After")
        
        #expect(rendering.attributedString.string == "Before")
    }
    
    
    @Test func sourceSizeLimitUsesUTF8Bytes() {
        
        let limit = MarkdownAttributedStringRenderer.maximumSourceByteCount
        let exactASCII = String(repeating: "a", count: limit)
        let exactMultibyte = String(repeating: "é", count: limit / 2)
        
        #expect(MarkdownAttributedStringRenderer.isWithinSourceLimit(exactASCII))
        #expect(!MarkdownAttributedStringRenderer.isWithinSourceLimit(exactASCII + "a"))
        #expect(MarkdownAttributedStringRenderer.isWithinSourceLimit(exactMultibyte))
        #expect(!MarkdownAttributedStringRenderer.isWithinSourceLimit(exactMultibyte + "é"))
        
        let message = MarkdownAttributedStringRenderer.render(markdown: exactASCII + "a").attributedString.string
        let expectedMessage = String(
            localized: "MarkdownPreview.tooLarge",
            defaultValue: "Markdown preview is unavailable for documents larger than 128 KB.",
            table: "Document"
        )
        #expect(message == expectedMessage)
    }
}


private extension Range<String.Index> {
    
    func nsRange(in string: String) -> NSRange {
        
        NSRange(self, in: string)
    }
}


private extension NSAttributedString {
    
    var paragraphStyles: [NSParagraphStyle] {
        
        var styles: [NSParagraphStyle] = []
        self.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: self.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle {
                styles.append(style)
            }
        }
        return styles
    }
}
