//
//  MarkdownHTMLRendererTests.swift
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

import Foundation
import Testing
@testable import CotEditor

struct MarkdownHTMLRendererTests {
    
    @Test func inlineMarkup() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            # Heading & details
            
            A *small* **strong** ~~deleted~~ ***both*** `a < b`.
            """)
        
        #expect(html.contains("<h1>Heading &amp; details</h1>"))
        #expect(html.contains("<p>A <em>small</em> <strong>strong</strong> <del>deleted</del> <em><strong>both</strong></em> <code>a &lt; b</code>.</p>"))
    }
    
    
    @Test func nestedBlocks() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            > A quote
            
            3. first
               - nested
            4. second
            
            ```swift
            let value = 1 < 2
            ```
            
            ---
            """)
        
        #expect(html.contains("<blockquote><p>A quote</p></blockquote>"))
        #expect(html.contains("<ol start=\"3\"><li><p>first</p><ul><li><p>nested</p></li></ul></li><li><p>second</p></li></ol>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let value = 1 &lt; 2\n</code></pre>"))
        #expect(html.contains("<hr>"))
        #expect(!html.contains("⸻"))
    }
    
    
    @Test func preservesEmptyListItems() {
        
        let orderedHTML = MarkdownHTMLRenderer.render(markdown: "1. first\n2.\n3. third")
        let unorderedHTML = MarkdownHTMLRenderer.render(markdown: "- first\n-\n- third")
        let leadingEmptyHTML = MarkdownHTMLRenderer.render(markdown: "-\n- second")
        let nestedOrderedHTML = MarkdownHTMLRenderer.render(markdown: "-\n  3. nested")
        
        #expect(orderedHTML.contains("<ol><li><p>first</p></li><li></li><li><p>third</p></li></ol>"))
        #expect(unorderedHTML.contains("<ul><li><p>first</p></li><li></li><li><p>third</p></li></ul>"))
        #expect(leadingEmptyHTML.contains("<ul><li></li><li><p>second</p></li></ul>"))
        #expect(nestedOrderedHTML.contains("<ul><li><ol start=\"3\"><li><p>nested</p></li></ol></li></ul>"))
        #expect(!nestedOrderedHTML.contains("<ol start=\"3\"><li></li>"))
    }
    
    
    @Test func table() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            | Left | Right |
            |:-----|------:|
            | A    | B     |
            """)
        
        #expect(html.contains("<table>"))
        #expect(html.contains("<thead><tr><th class=\"align-left\">Left</th><th class=\"align-right\">Right</th></tr></thead>"))
        #expect(html.contains("<tbody><tr><td class=\"align-left\">A</td><td class=\"align-right\">B</td></tr></tbody>"))
        #expect(html.contains("</table>"))
    }
    
    
    @Test func tablePreservesEmptyCells() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            | A |   | C |
            |---|---|---|
            |   | B |   |
            """)
        
        #expect(html.contains("<thead><tr><th class=\"align-left\">A</th><th class=\"align-left\"></th><th class=\"align-left\">C</th></tr></thead>"))
        #expect(html.contains("<tbody><tr><td class=\"align-left\"></td><td class=\"align-left\">B</td><td class=\"align-left\"></td></tr></tbody>"))
    }
    
    
    @Test func tablePreservesEmptyHeaderAndBodyRows() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            |   |   |
            |---|---|
            | A | B |
            |   |   |
            | C | D |
            """)
        
        #expect(html.contains("<table><thead><tr><th class=\"align-left\"></th><th class=\"align-left\"></th></tr></thead>"))
        #expect(html.contains("<tbody><tr><td class=\"align-left\">A</td><td class=\"align-left\">B</td></tr></tbody><tbody><tr><td class=\"align-left\"></td><td class=\"align-left\"></td></tr></tbody><tbody><tr><td class=\"align-left\">C</td><td class=\"align-left\">D</td></tr></tbody>"))
    }
    
    
    @Test func externalLinkAllowlist() throws {
        
        let httpsURL = try #require(URL(string: "https://example.com"))
        let httpURL = try #require(URL(string: "http://example.com"))
        let mailtoURL = try #require(URL(string: "mailto:editor@example.com"))
        let scriptURL = try #require(URL(string: "javascript:alert(1)"))
        let dataURL = try #require(URL(string: "data:text/html,unsafe"))
        let customURL = try #require(URL(string: "x-coteditor:command"))
        let relativeURL = try #require(URL(string: "guide.md"))
        let hostlessHTTPSURL = try #require(URL(string: "https:relative"))
        let emptyMailtoURL = try #require(URL(string: "mailto:?subject=Preview"))
        
        #expect(MarkdownHTMLRenderer.isAllowedExternalLink(httpsURL))
        #expect(MarkdownHTMLRenderer.isAllowedExternalLink(httpURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(mailtoURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(scriptURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(dataURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(customURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(relativeURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(hostlessHTTPSURL))
        #expect(!MarkdownHTMLRenderer.isAllowedExternalLink(emptyMailtoURL))
    }
    
    
    @Test func sanitizesLinks() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            [Web](https://example.com/?a=1&b=2 "A & B")
            [Script](javascript:alert(1))
            [Local](guide.md)
            """)
        
        #expect(html.contains("<a href=\"https://example.com/?a=1&amp;b=2\" title=\"A &amp; B\">Web</a>"))
        #expect(html.contains("Script"))
        #expect(html.contains("Local"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(!html.contains("href=\"guide.md"))
    }
    
    
    @Test func doesNotLoadImages() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            ![Local <image>](images/preview.png "A & B")
            ![File](file:///tmp/preview.png)
            ![Remote](https://example.com/preview.png)
            ![Script](javascript:alert(1))
            ![Data](data:image/png;base64,AAAA)
            ![Custom](image-cache:preview)
            ![Network path](//example.com/preview.png)
            ![Absolute](/tmp/preview.png)
            ![Traversal](../preview.png)
            ![Encoded traversal](%2e%2e/preview.png)
            """)
        
        #expect(html.contains("Local &lt;image&gt;"))
        #expect(html.contains("File"))
        #expect(html.contains("Remote"))
        #expect(html.contains("Script"))
        #expect(html.contains("Data"))
        #expect(html.contains("Custom"))
        #expect(html.contains("Network path"))
        #expect(html.contains("Absolute"))
        #expect(html.contains("Traversal"))
        #expect(html.contains("Encoded traversal"))
        #expect(!html.contains("<img"))
    }
    
    
    @Test func escapesRawHTML() {
        
        let html = MarkdownHTMLRenderer.render(markdown: "<script>alert(\"unsafe\")</script><b>text</b>")
        
        #expect(html.contains("&lt;script&gt;alert(&quot;unsafe&quot;)&lt;/script&gt;&lt;b&gt;text&lt;/b&gt;"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<b>text</b>"))
    }
    
    
    @Test func sanitizesCodeFenceLanguage() {
        
        let html = MarkdownHTMLRenderer.render(markdown: """
            ```swift" onmouseover="alert(1)
            code
            ```
            """)
        
        #expect(html.contains("<pre><code class=\"language-swift\">code\n</code></pre>"))
        #expect(!html.contains("onmouseover"))
    }
    
    
    @Test func preservesUnicodeText() {
        
        let html = MarkdownHTMLRenderer.render(markdown: "# 日本語 & Café\n\n*Привет* 📚")
        
        #expect(html.contains("<h1>日本語 &amp; Café</h1>"))
        #expect(html.contains("<p><em>Привет</em> 📚</p>"))
    }
    
    
    @Test func completeRestrictedDocument() {
        
        let html = MarkdownHTMLRenderer.render(markdown: "Preview")
        
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("Content-Security-Policy"))
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains("img-src 'none'"))
        #expect(html.contains("<title>Markdown Preview</title>"))
        #expect(html.contains("<body><p>Preview</p></body>"))
        #expect(html.hasSuffix("</html>"))
    }
}
