//
//  MarkdownHTMLRenderer.swift
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

/// Converts Markdown to a self-contained HTML document suitable for a WebKit preview.
enum MarkdownHTMLRenderer {
    
    /// Converts the given Markdown source to a sanitized HTML document.
    ///
    /// Raw HTML is never passed through. If Foundation cannot parse the source, the escaped
    /// source is returned in a plain preformatted block instead.
    static func render(markdown: String) -> String {
        
        let body: String
        do {
            let attributedString = try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .full, failurePolicy: .throwError)
            )
            body = self.renderBody(attributedString)
        } catch {
            body = "<pre class=\"markdown-source\">\(self.escapeHTML(markdown))</pre>"
        }
        
        let title = String(localized: "Toolbar.markdownPreview.label",
                           defaultValue: "Markdown Preview", table: "Document")
        return self.document(body: body, title: title)
    }
    
    
    /// Returns whether an external link can be opened from the Markdown preview.
    static func isAllowedExternalLink(_ url: URL) -> Bool {
        
        switch url.scheme?.lowercased() {
            case "http", "https":
                return url.host?.isEmpty == false
            default:
                return false
        }
    }
}


// MARK: - Rendering

private extension MarkdownHTMLRenderer {
    
    struct OpenBlock {
        
        var intent: PresentationIntent.IntentType
        var closingHTML: String
    }
    
    
    /// Renders the body by reconciling the presentation-intent path of consecutive runs.
    static func renderBody(_ attributedString: AttributedString) -> String {
        
        var html = String()
        var openBlocks: [OpenBlock] = []
        
        for run in attributedString.runs {
            let previousPath = openBlocks.map(\.intent)
            let presentationIntent = run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]
            let path = presentationIntent.map { Array($0.components.reversed()) } ?? []
            let commonCount = zip(openBlocks, path).prefix { block, intent in
                block.intent.identity == intent.identity
            }.count
            let previousTableRowIdentity = self.tableRowIdentity(in: previousPath)
            let remainsInTableRow = previousTableRowIdentity != nil && previousTableRowIdentity == self.tableRowIdentity(in: path)
            let previousTableIdentity = self.tableIdentity(in: previousPath)
            let continuesTable = previousTableIdentity != nil && previousTableIdentity == self.tableIdentity(in: path)
            
            for block in openBlocks[commonCount...].reversed() {
                html += block.closingHTML
                if case .tableCell(let columnIndex) = block.intent.kind, !remainsInTableRow {
                    html += self.emptyTableCells(after: columnIndex, in: previousPath)
                }
            }
            openBlocks.removeLast(openBlocks.count - commonCount)
            
            html += self.emptyListItems(from: previousPath, to: path, commonCount: commonCount)
            if continuesTable {
                html += self.emptyTableRows(from: previousPath, to: path)
            }
            
            if remainsInTableRow,
               let previousColumn = self.tableCellColumn(in: previousPath),
               let column = self.tableCellColumn(in: path),
               column > previousColumn + 1
            {
                html += self.emptyTableCells(in: (previousColumn + 1)..<column, path: path)
            }
            
            for index in commonCount..<path.count {
                if case .listItem(let ordinal) = path[index].kind,
                   ordinal > 1,
                   self.isOpeningUnorderedList(at: index, commonCount: commonCount, in: path)
                {
                    html += Array(repeating: "<li></li>", count: ordinal - 1).joined()
                }
                if case .tableRow(let rowIndex) = path[index].kind,
                   !continuesTable,
                   self.isOpeningTableRow(at: index + 1, commonCount: commonCount, in: path)
                {
                    html += self.emptyTableRow(in: path, isHeader: true)
                    html += (1..<rowIndex).map { _ in self.emptyTableRow(in: path, isHeader: false) }.joined()
                }
                if case .tableCell(let columnIndex) = path[index].kind,
                   self.isOpeningTableRow(at: index, commonCount: commonCount, in: path)
                {
                    html += self.emptyTableCells(in: 0..<columnIndex, path: path)
                }
                let element = self.blockHTML(for: path[index], at: index, in: path)
                html += element.opening
                openBlocks.append(OpenBlock(intent: path[index], closingHTML: element.closing))
            }
            
            guard !path.contains(where: { intent in
                if case .thematicBreak = intent.kind { true } else { false }
            }) else { continue }
            
            html += self.inlineHTML(
                String(attributedString[run.range].characters),
                intent: run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self],
                link: run[AttributeScopes.FoundationAttributes.LinkAttribute.self],
                imageURL: run[AttributeScopes.FoundationAttributes.ImageURLAttribute.self],
                title: run[AttributeScopes.FoundationAttributes.AlternateDescriptionAttribute.self]
            )
        }
        
        let finalPath = openBlocks.map(\.intent)
        for block in openBlocks.reversed() {
            html += block.closingHTML
            if case .tableCell(let columnIndex) = block.intent.kind {
                html += self.emptyTableCells(after: columnIndex, in: finalPath)
            }
        }
        
        return html
    }
    
    
    /// Returns the opening and closing HTML for a block presentation intent.
    static func blockHTML(
        for intent: PresentationIntent.IntentType,
        at index: Int,
        in path: [PresentationIntent.IntentType]
    ) -> (opening: String, closing: String) {
        
        switch intent.kind {
            case .paragraph:
                return ("<p>", "</p>")
                
            case .header(let level):
                let level = min(max(level, 1), 6)
                return ("<h\(level)>", "</h\(level)>")
                
            case .orderedList:
                let ordinal = path[(index + 1)...].compactMap { component -> Int? in
                    if case .listItem(let ordinal) = component.kind { ordinal } else { nil }
                }.first
                let start = ordinal.flatMap { $0 == 1 ? nil : " start=\"\($0)\"" } ?? ""
                return ("<ol\(start)>", "</ol>")
                
            case .unorderedList:
                return ("<ul>", "</ul>")
                
            case .listItem:
                return ("<li>", "</li>")
                
            case .codeBlock(let languageHint):
                let languageClass = self.languageClass(for: languageHint)
                return ("<pre><code\(languageClass)>", "</code></pre>")
                
            case .blockQuote:
                return ("<blockquote>", "</blockquote>")
                
            case .thematicBreak:
                return ("<hr>", "")
                
            case .table:
                return ("<table>", "</table>")
                
            case .tableHeaderRow:
                return ("<thead><tr>", "</tr></thead>")
                
            case .tableRow:
                return ("<tbody><tr>", "</tr></tbody>")
                
            case .tableCell(let columnIndex):
                let isHeader = path.contains { component in
                    if case .tableHeaderRow = component.kind { true } else { false }
                }
                let tag = isHeader ? "th" : "td"
                let alignmentClass = self.tableAlignmentClass(columnIndex: columnIndex, in: path)
                return ("<\(tag)\(alignmentClass)>", "</\(tag)>")
                
            @unknown default:
                return ("", "")
        }
    }
    
    
    /// Renders a single attributed run without allowing source text to become markup.
    static func inlineHTML(
        _ string: String,
        intent: InlinePresentationIntent?,
        link: URL?,
        imageURL: URL?,
        title: String?
    ) -> String {
        
        if intent?.contains(.lineBreak) == true {
            return "<br>"
        }
        
        var html: String
        html = self.escapeHTML(string)
        
        if intent?.contains(.code) == true {
            html = "<code>\(html)</code>"
        }
        if intent?.contains(.strikethrough) == true {
            html = "<del>\(html)</del>"
        }
        if intent?.contains(.stronglyEmphasized) == true {
            html = "<strong>\(html)</strong>"
        }
        if intent?.contains(.emphasized) == true {
            html = "<em>\(html)</em>"
        }
        if let link, self.isAllowedExternalLink(link) {
            let titleAttribute = imageURL == nil ? title.map { " title=\"\(self.escapeHTML($0))\"" } ?? "" : ""
            html = "<a href=\"\(self.escapeHTML(link.absoluteString))\"\(titleAttribute)>\(html)</a>"
        }
        
        return html
    }
    
    
    /// Emits list items omitted by Foundation because their source items have no contents.
    static func emptyListItems(
        from previousPath: [PresentationIntent.IntentType],
        to path: [PresentationIntent.IntentType],
        commonCount: Int
    ) -> String {
        
        guard let listIndex = (0..<commonCount).last(where: { index in
            switch path[index].kind {
                case .orderedList, .unorderedList: true
                default: false
            }
        }) else { return "" }
        
        let previousOrdinal = previousPath[(listIndex + 1)...].compactMap { component -> Int? in
            if case .listItem(let ordinal) = component.kind { ordinal } else { nil }
        }.first
        let ordinal = path[(listIndex + 1)...].compactMap { component -> Int? in
            if case .listItem(let ordinal) = component.kind { ordinal } else { nil }
        }.first
        guard let previousOrdinal, let ordinal, ordinal > previousOrdinal + 1 else { return "" }
        
        return Array(repeating: "<li></li>", count: ordinal - previousOrdinal - 1).joined()
    }
    
    
    /// Returns whether opening the item at the given index also opens an unordered list.
    static func isOpeningUnorderedList(
        at itemIndex: Int,
        commonCount: Int,
        in path: [PresentationIntent.IntentType]
    ) -> Bool {
        
        guard let listIndex = path[..<itemIndex].lastIndex(where: { component in
            switch component.kind {
                case .orderedList, .unorderedList: true
                default: false
            }
        }), listIndex >= commonCount else { return false }
        
        if case .unorderedList = path[listIndex].kind { return true }
        return false
    }
    
    
    /// Returns the identity of the table row in the given intent path.
    static func tableRowIdentity(in path: [PresentationIntent.IntentType]) -> Int? {
        
        path.first { component in
            switch component.kind {
                case .tableHeaderRow, .tableRow: true
                default: false
            }
        }?.identity
    }
    
    
    /// Returns the identity of the table in the given intent path.
    static func tableIdentity(in path: [PresentationIntent.IntentType]) -> Int? {
        
        path.first { component in
            if case .table = component.kind { true } else { false }
        }?.identity
    }
    
    
    /// Returns the ordinal of a body row in the given table-intent path.
    static func tableBodyRowOrdinal(in path: [PresentationIntent.IntentType]) -> Int? {
        
        path.compactMap { component -> Int? in
            if case .tableRow(let ordinal) = component.kind { ordinal } else { nil }
        }.first
    }
    
    
    /// Returns the represented table-cell column in the given intent path.
    static func tableCellColumn(in path: [PresentationIntent.IntentType]) -> Int? {
        
        path.compactMap { component -> Int? in
            if case .tableCell(let columnIndex) = component.kind { columnIndex } else { nil }
        }.first
    }
    
    
    /// Returns whether opening the cell at the given index also opens its table row.
    static func isOpeningTableRow(
        at cellIndex: Int,
        commonCount: Int,
        in path: [PresentationIntent.IntentType]
    ) -> Bool {
        
        path[..<cellIndex].lastIndex { component in
            switch component.kind {
                case .tableHeaderRow, .tableRow: true
                default: false
            }
        }.map { $0 >= commonCount } == true
    }
    
    
    /// Emits empty cells between the given column and the end of its table row.
    static func emptyTableCells(after columnIndex: Int, in path: [PresentationIntent.IntentType]) -> String {
        
        guard let columnCount = path.compactMap({ component -> Int? in
            if case .table(let columns) = component.kind { columns.count } else { nil }
        }).first, columnIndex + 1 < columnCount else { return "" }
        
        return self.emptyTableCells(in: (columnIndex + 1)..<columnCount, path: path)
    }
    
    
    /// Emits all-empty body rows omitted between represented table rows.
    static func emptyTableRows(
        from previousPath: [PresentationIntent.IntentType],
        to path: [PresentationIntent.IntentType]
    ) -> String {
        
        guard let ordinal = self.tableBodyRowOrdinal(in: path) else { return "" }
        
        let firstMissingOrdinal = self.tableBodyRowOrdinal(in: previousPath).map { $0 + 1 } ?? 1
        guard firstMissingOrdinal < ordinal else { return "" }
        
        return (firstMissingOrdinal..<ordinal).map { _ in
            self.emptyTableRow(in: path, isHeader: false)
        }.joined()
    }
    
    
    /// Emits an all-empty table row with the table's complete column structure.
    static func emptyTableRow(in path: [PresentationIntent.IntentType], isHeader: Bool) -> String {
        
        guard let columnCount = path.compactMap({ component -> Int? in
            if case .table(let columns) = component.kind { columns.count } else { nil }
        }).first else { return "" }
        
        let cells = self.emptyTableCells(in: 0..<columnCount, path: path, isHeader: isHeader)
        return isHeader ? "<thead><tr>\(cells)</tr></thead>" : "<tbody><tr>\(cells)</tr></tbody>"
    }
    
    
    /// Emits empty table cells for the given column indexes.
    static func emptyTableCells(
        in columns: Range<Int>,
        path: [PresentationIntent.IntentType],
        isHeader: Bool? = nil
    ) -> String {
        
        let isHeader = isHeader ?? path.contains { component in
            if case .tableHeaderRow = component.kind { true } else { false }
        }
        let tag = isHeader ? "th" : "td"
        
        return columns.map { columnIndex in
            let alignmentClass = self.tableAlignmentClass(columnIndex: columnIndex, in: path)
            return "<\(tag)\(alignmentClass)></\(tag)>"
        }.joined()
    }
}


// MARK: - Sanitization

private extension MarkdownHTMLRenderer {
    
    /// Escapes text for both HTML text and double-quoted attribute contexts.
    static func escapeHTML(_ string: String) -> String {
        
        var escaped = String()
        escaped.reserveCapacity(string.utf8.count)
        
        for character in string {
            switch character {
                case "&": escaped += "&amp;"
                case "<": escaped += "&lt;"
                case ">": escaped += "&gt;"
                case "\"": escaped += "&quot;"
                case "'": escaped += "&#39;"
                default: escaped.append(character)
            }
        }
        
        return escaped
    }
    
    
    /// Returns a safe CSS class for a fenced-code language hint.
    static func languageClass(for hint: String?) -> String {
        
        guard let hint else { return "" }
        
        let identifier = hint.prefix { character in
            character.isASCII && (character.isLetter || character.isNumber || "_+-".contains(character))
        }
        guard !identifier.isEmpty else { return "" }
        
        return " class=\"language-\(identifier)\""
    }
    
    
    /// Returns the table-column alignment as a fixed CSS class.
    static func tableAlignmentClass(columnIndex: Int, in path: [PresentationIntent.IntentType]) -> String {
        
        guard let columns = path.compactMap({ component -> [PresentationIntent.TableColumn]? in
            if case .table(let columns) = component.kind { columns } else { nil }
        }).first,
              columns.indices.contains(columnIndex)
        else { return "" }
        
        return switch columns[columnIndex].alignment {
            case .left: " class=\"align-left\""
            case .center: " class=\"align-center\""
            case .right: " class=\"align-right\""
            @unknown default: ""
        }
    }
}


// MARK: - Document

private extension MarkdownHTMLRenderer {
    
    /// Wraps rendered Markdown in a complete, script-free HTML document.
    static func document(body: String, title: String) -> String {
        
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(self.escapeHTML(title))</title>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; object-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; img-src 'none'; style-src 'unsafe-inline'">
        <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
          max-width: 52rem;
          margin: 0 auto;
          padding: 2rem;
          color: CanvasText;
          background: Canvas;
          font: 15px/1.6 system-ui, -apple-system, sans-serif;
          overflow-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid color-mix(in srgb, CanvasText 20%, transparent); }
        a { color: LinkText; }
        blockquote { margin-inline: 0; padding-inline: 1em; border-inline-start: 0.25em solid color-mix(in srgb, CanvasText 25%, transparent); opacity: 0.85; }
        code { padding: 0.15em 0.3em; border-radius: 0.25em; background: color-mix(in srgb, CanvasText 8%, transparent); font-family: ui-monospace, monospace; }
        pre { padding: 1em; overflow: auto; border-radius: 0.4em; background: color-mix(in srgb, CanvasText 8%, transparent); }
        pre code { padding: 0; background: none; white-space: pre; }
        hr { height: 1px; border: 0; background: color-mix(in srgb, CanvasText 20%, transparent); }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 0.4em 0.7em; border: 1px solid color-mix(in srgb, CanvasText 20%, transparent); }
        .align-left { text-align: left; }
        .align-center { text-align: center; }
        .align-right { text-align: right; }
        </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }
}
