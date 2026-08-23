//
//  MarkdownAttributedStringRenderer.swift
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
import Foundation

/// An immutable native rendering transferred from the serial renderer actor.
struct MarkdownPreviewRendering {
    
    let attributedString: NSAttributedString
    let minimumContentWidth: CGFloat
    
    
    init(attributedString: NSAttributedString, minimumContentWidth: CGFloat = 0) {
        
        // Copying prevents a mutable subclass supplied by future callers from crossing actors.
        self.attributedString = NSAttributedString(attributedString: attributedString)
        self.minimumContentWidth = minimumContentWidth
    }
}


/// Converts Markdown to rich native text without requiring WebKit or network access.
enum MarkdownAttributedStringRenderer {
    
    static let maximumSourceByteCount = 128 * 1024
    private static let tableColumnWidth: CGFloat = 160
    
    
    /// Converts the given Markdown source to a styled, selectable attributed string.
    static func render(markdown: String) -> MarkdownPreviewRendering {
        
        guard self.isWithinSourceLimit(markdown) else {
            return MarkdownPreviewRendering(attributedString: self.oversizedPreviewMessage())
        }
        
        let attributedString: AttributedString
        do {
            attributedString = try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .full, failurePolicy: .throwError)
            )
        } catch {
            return MarkdownPreviewRendering(attributedString: self.fallback(markdown))
        }
        
        var blocks: [RenderedBlock] = []
        var currentBlock: RenderedBlock?
        
        for run in attributedString.runs {
            guard !Task.isCancelled else {
                return MarkdownPreviewRendering(attributedString: NSAttributedString())
            }
            
            let presentationIntent = run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]
            let path = presentationIntent.map { Array($0.components.reversed()) } ?? []
            let descriptor = BlockDescriptor(path: path)
            let paragraphIdentity = path.last { component in
                if case .paragraph = component.kind { true } else { false }
            }?.identity
            
            if currentBlock?.descriptor.identity != descriptor.identity {
                if let currentBlock {
                    blocks.append(currentBlock)
                }
                currentBlock = RenderedBlock(descriptor: descriptor)
            } else if
                let paragraphIdentity,
                let previousIdentity = currentBlock?.paragraphIdentity,
                paragraphIdentity != previousIdentity,
                currentBlock?.content.length != 0
            {
                currentBlock?.content.append(NSAttributedString(string: "\n"))
            }
            currentBlock?.paragraphIdentity = paragraphIdentity
            
            guard !descriptor.isThematicBreak else { continue }
            
            let inlineIntent = run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]
            let string = inlineIntent?.contains(.lineBreak) == true
                ? "\n"
                : String(attributedString[run.range].characters)
            let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self]
            let imageURL = run[AttributeScopes.FoundationAttributes.ImageURLAttribute.self]
            currentBlock?.content.append(self.inlineString(
                string,
                intent: inlineIntent,
                link: imageURL == nil ? link : nil,
                baseFont: descriptor.baseFont
            ))
        }
        
        if let currentBlock {
            blocks.append(currentBlock)
        }
        
        return MarkdownPreviewRendering(
            attributedString: self.compose(blocks),
            minimumContentWidth: self.minimumContentWidth(for: blocks)
        )
    }
    
    
    /// Whether a preview link may be handed to the system browser.
    static func isAllowedExternalLink(_ url: URL) -> Bool {
        
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty
        else { return false }
        
        return true
    }
    
    
    /// Whether rendering the source is bounded enough to keep preview work responsive.
    static func isWithinSourceLimit(_ markdown: String) -> Bool {
        
        markdown.utf8.count <= self.maximumSourceByteCount
    }
}


// MARK: - Rendering

private extension MarkdownAttributedStringRenderer {
    
    struct RenderedBlock {
        
        var descriptor: BlockDescriptor
        var content = NSMutableAttributedString()
        var paragraphIdentity: Int?
    }
    
    
    struct TableContext {
        
        var column: Int
        var columnCount: Int
        var alignments: [NSTextAlignment]
        var rowIdentity: Int
        var rowOrdinal: Int?
        var tableIdentity: Int
        var isHeader: Bool
    }
    
    
    struct ListItemContext {
        
        var listIdentity: Int
        var itemIdentity: Int
        var ordinal: Int
        var isOrdered: Bool
    }
    
    
    struct BlockDescriptor {
        
        enum Kind {
            
            case paragraph
            case header(level: Int)
            case code
            case thematicBreak
            case tableCell(TableContext)
            case fallback
        }
        
        private struct Resolution {
            
            var kind: Kind
            var identity: Int
        }
        
        var kind: Kind
        var identity: Int
        var listPath: [ListItemContext]
        var quoteDepth: Int
        
        var listDepth: Int { self.listPath.count }
        var listOrdinal: Int? { self.listPath.last?.ordinal }
        var listIdentity: Int? { self.listPath.last?.listIdentity }
        var listItemIdentity: Int? { self.listPath.last?.itemIdentity }
        var isOrderedList: Bool { self.listPath.last?.isOrdered ?? false }
        
        var isThematicBreak: Bool {
            
            if case .thematicBreak = self.kind { true } else { false }
        }
        
        var tableContext: TableContext? {
            
            if case .tableCell(let context) = self.kind {
                context
            } else {
                nil
            }
        }
        
        var baseFont: NSFont {
            
            switch self.kind {
                case .header(let level):
                    NSFont.systemFont(ofSize: [28, 23, 19, 17, 15, 15][min(max(level, 1), 6) - 1], weight: .bold)
                case .code:
                    NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                default:
                    NSFont.systemFont(ofSize: 15)
            }
        }
        
        
        init(path: [PresentationIntent.IntentType]) {
            
            let resolution = Self.resolveBlock(in: path)
            self.kind = resolution.kind
            self.identity = resolution.identity
            
            let lists = path.compactMap { component -> (identity: Int, isOrdered: Bool)? in
                switch component.kind {
                    case .orderedList: (component.identity, true)
                    case .unorderedList: (component.identity, false)
                    default: nil
                }
            }
            let listItems = path.compactMap { component -> (identity: Int, ordinal: Int)? in
                if case .listItem(let ordinal) = component.kind {
                    (component.identity, ordinal)
                } else {
                    nil
                }
            }
            self.listPath = zip(lists, listItems).map { list, item in
                ListItemContext(
                    listIdentity: list.identity,
                    itemIdentity: item.identity,
                    ordinal: item.ordinal,
                    isOrdered: list.isOrdered
                )
            }
            self.quoteDepth = path.count { component in
                if case .blockQuote = component.kind { true } else { false }
            }
        }
        
        
        /// Returns a copy scoped to the given outer list depth.
        func truncated(toListDepth depth: Int) -> Self {
            
            var descriptor = self
            descriptor.listPath = Array(self.listPath.prefix(depth))
            return descriptor
        }
        
        
        /// Resolves the visible block kind and its stable presentation identity.
        private static func resolveBlock(in path: [PresentationIntent.IntentType]) -> Resolution {
            
            if let resolution = self.resolveTableCell(in: path) {
                return resolution
            }
            if let component = path.first(where: { component in
                if case .codeBlock = component.kind { true } else { false }
            }) {
                return Resolution(kind: .code, identity: component.identity)
            }
            if let component = path.first(where: { component in
                if case .thematicBreak = component.kind { true } else { false }
            }) {
                return Resolution(kind: .thematicBreak, identity: component.identity)
            }
            if
                let component = path.first(where: { component in
                    if case .header = component.kind { true } else { false }
                }),
                case .header(let level) = component.kind
            {
                return Resolution(kind: .header(level: level), identity: component.identity)
            }
            if let component = path.last(where: { component in
                if case .paragraph = component.kind { true } else { false }
            }) {
                return Resolution(kind: .paragraph, identity: component.identity)
            }
            if let component = path.last {
                return Resolution(kind: .fallback, identity: component.identity)
            }
            return Resolution(kind: .paragraph, identity: 0)
        }
        
        
        /// Resolves table metadata kept outside the visible inline contents.
        private static func resolveTableCell(in path: [PresentationIntent.IntentType]) -> Resolution? {
            
            guard
                let tableComponent = path.first(where: { component in
                    if case .table = component.kind { true } else { false }
                }),
                let cell = path.first(where: { component in
                    if case .tableCell = component.kind { true } else { false }
                }),
                let row = path.first(where: { component in
                    switch component.kind {
                        case .tableHeaderRow, .tableRow: true
                        default: false
                    }
                }),
                case .table(let columns) = tableComponent.kind,
                case .tableCell(let column) = cell.kind
            else { return nil }
            
            let isHeader = if case .tableHeaderRow = row.kind { true } else { false }
            let rowOrdinal: Int? = if case .tableRow(let ordinal) = row.kind { ordinal } else { nil }
            let alignments = columns.map { column in
                switch column.alignment {
                    case .left: NSTextAlignment.left
                    case .center: NSTextAlignment.center
                    case .right: NSTextAlignment.right
                    @unknown default: NSTextAlignment.left
                }
            }
            let context = TableContext(
                column: column,
                columnCount: columns.count,
                alignments: alignments,
                rowIdentity: row.identity,
                rowOrdinal: rowOrdinal,
                tableIdentity: tableComponent.identity,
                isHeader: isHeader
            )
            return Resolution(
                kind: .tableCell(context),
                identity: cell.identity
            )
        }
    }
    
    
    /// Composes block renderings into a TextKit document.
    static func compose(_ blocks: [RenderedBlock]) -> NSMutableAttributedString {
        
        let output = NSMutableAttributedString()
        var previousTableDescriptor: BlockDescriptor?
        var renderedListItems: Set<Int> = []
        var renderedListOrdinals: [Int: Int] = [:]
        
        for block in blocks {
            guard !Task.isCancelled else { break }
            
            if
                let previousDescriptor = previousTableDescriptor,
                previousDescriptor.tableContext?.tableIdentity != block.descriptor.tableContext?.tableIdentity
            {
                self.finishTable(after: previousDescriptor, addsBlankLine: true, output: output)
                previousTableDescriptor = nil
            }
            
            let includesListMarker = self.prepareListAncestry(
                for: block.descriptor,
                renderedListItems: &renderedListItems,
                renderedListOrdinals: &renderedListOrdinals,
                output: output
            )
            
            if block.descriptor.tableContext != nil {
                if
                    previousTableDescriptor == nil,
                    block.descriptor.listDepth > 0 || block.descriptor.quoteDepth > 0
                {
                    self.appendContainerDecoration(
                        for: block.descriptor,
                        includesListMarker: includesListMarker,
                        output: output
                    )
                }
                self.appendTableTransition(from: previousTableDescriptor, to: block.descriptor, output: output)
                self.appendTableCell(block, output: output)
                previousTableDescriptor = block.descriptor
                continue
            }
            
            let paragraph = NSMutableAttributedString()
            let prefix = self.prefix(for: block.descriptor, includesListMarker: includesListMarker)
            if !prefix.isEmpty {
                paragraph.append(NSAttributedString(
                    string: prefix,
                    attributes: self.baseAttributes(font: block.descriptor.baseFont)
                ))
            }
            if block.descriptor.isThematicBreak {
                paragraph.append(NSAttributedString(
                    string: "────────────────",
                    attributes: [
                        .font: block.descriptor.baseFont,
                        .foregroundColor: NSColor.separatorColor,
                    ]
                ))
            } else {
                paragraph.append(block.content)
            }
            paragraph.append(NSAttributedString(string: "\n", attributes: self.baseAttributes(font: block.descriptor.baseFont)))
            paragraph.addAttribute(
                .paragraphStyle,
                value: self.paragraphStyle(for: block.descriptor, includesListMarker: includesListMarker),
                range: paragraph.fullRange
            )
            
            if case .code = block.descriptor.kind, paragraph.length > 0 {
                paragraph.addAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, range: paragraph.fullRange)
            }
            output.append(paragraph)
        }
        
        if let previousTableDescriptor {
            self.finishTable(after: previousTableDescriptor, addsBlankLine: false, output: output)
        }
        
        return output
    }
    
    
    /// Emits newly discovered empty ancestor items and returns whether the visible block needs its own marker.
    static func prepareListAncestry(
        for descriptor: BlockDescriptor,
        renderedListItems: inout Set<Int>,
        renderedListOrdinals: inout [Int: Int],
        output: NSMutableAttributedString
    ) -> Bool {
        
        guard !descriptor.listPath.isEmpty else { return true }
        
        var includesDeepestMarker = false
        for (index, context) in descriptor.listPath.enumerated() {
            guard renderedListItems.insert(context.itemIdentity).inserted else { continue }
            
            let scopedDescriptor = descriptor.truncated(toListDepth: index + 1)
            self.appendOmittedListItems(
                before: scopedDescriptor,
                renderedListOrdinals: &renderedListOrdinals,
                output: output
            )
            if index == descriptor.listPath.indices.last {
                includesDeepestMarker = true
            } else {
                self.appendContainerDecoration(
                    for: scopedDescriptor,
                    includesListMarker: true,
                    output: output
                )
            }
        }
        
        return includesDeepestMarker
    }
    
    
    /// Emits list items for source entries that Foundation omitted because they are empty.
    static func appendOmittedListItems(
        before descriptor: BlockDescriptor,
        renderedListOrdinals: inout [Int: Int],
        output: NSMutableAttributedString
    ) {
        
        guard
            let listIdentity = descriptor.listIdentity,
            let ordinal = descriptor.listOrdinal
        else { return }
        
        let firstMissingOrdinal = renderedListOrdinals[listIdentity].map { $0 + 1 }
            ?? (descriptor.isOrderedList ? ordinal : 1)
        if firstMissingOrdinal < ordinal {
            for missingOrdinal in firstMissingOrdinal..<ordinal {
                let marker = descriptor.isOrderedList ? "\(missingOrdinal). " : "• "
                let paragraph = NSMutableAttributedString(
                    string: marker + "\n",
                    attributes: self.baseAttributes(font: descriptor.baseFont)
                )
                paragraph.addAttribute(
                    .paragraphStyle,
                    value: self.paragraphStyle(for: descriptor),
                    range: paragraph.fullRange
                )
                output.append(paragraph)
            }
        }
        renderedListOrdinals[listIdentity] = ordinal
    }
    
    
    /// Keeps list or quote context visible when its first rendered child is a table.
    static func appendContainerDecoration(
        for descriptor: BlockDescriptor,
        includesListMarker: Bool,
        output: NSMutableAttributedString
    ) {
        
        let prefix = self.prefix(for: descriptor, includesListMarker: includesListMarker)
        guard !prefix.isEmpty else { return }
        
        let paragraph = NSMutableAttributedString(
            string: prefix + "\n",
            attributes: self.baseAttributes(font: descriptor.baseFont)
        )
        paragraph.addAttribute(
            .paragraphStyle,
            value: self.paragraphStyle(for: descriptor, includesListMarker: includesListMarker),
            range: paragraph.fullRange
        )
        output.append(paragraph)
    }
    
    
    /// Inserts omitted table cells and rows between two represented cells.
    static func appendTableTransition(
        from previousDescriptor: BlockDescriptor?,
        to descriptor: BlockDescriptor,
        output: NSMutableAttributedString
    ) {
        
        guard let table = descriptor.tableContext else { return }
        guard let previousDescriptor, let previousTable = previousDescriptor.tableContext else {
            self.startTable(at: descriptor, output: output)
            return
        }
        guard previousTable.tableIdentity == table.tableIdentity else {
            self.finishTable(after: previousDescriptor, addsBlankLine: true, output: output)
            self.startTable(at: descriptor, output: output)
            return
        }
        
        if previousTable.rowIdentity == table.rowIdentity {
            let tabCount = max(1, table.column - previousTable.column)
            self.appendTableControl(String(repeating: "\t", count: tabCount), descriptor: descriptor, output: output)
        } else {
            self.finishTableRow(after: previousDescriptor, output: output)
            self.appendMissingTableRows(from: previousTable, to: table, descriptor: descriptor, output: output)
            self.appendTableControl(String(repeating: "\t", count: table.column), descriptor: descriptor, output: output)
        }
    }
    
    
    /// Starts a table, reconstructing an omitted empty header or leading body rows.
    static func startTable(at descriptor: BlockDescriptor, output: NSMutableAttributedString) {
        
        guard let table = descriptor.tableContext else { return }
        if !table.isHeader {
            self.appendEmptyTableRows(count: 1, descriptor: descriptor, output: output)
            self.appendEmptyTableRows(count: max(0, (table.rowOrdinal ?? 1) - 1), descriptor: descriptor, output: output)
        }
        self.appendTableControl(String(repeating: "\t", count: table.column), descriptor: descriptor, output: output)
    }
    
    
    /// Reconstructs all-empty body rows omitted by Foundation's Markdown parser.
    static func appendMissingTableRows(
        from previousTable: TableContext,
        to table: TableContext,
        descriptor: BlockDescriptor,
        output: NSMutableAttributedString
    ) {
        
        guard !table.isHeader, let rowOrdinal = table.rowOrdinal else { return }
        let firstMissingOrdinal = previousTable.rowOrdinal.map { $0 + 1 } ?? 1
        self.appendEmptyTableRows(
            count: max(0, rowOrdinal - firstMissingOrdinal),
            descriptor: descriptor,
            output: output
        )
    }
    
    
    /// Appends one or more structurally complete empty table rows.
    static func appendEmptyTableRows(
        count: Int,
        descriptor: BlockDescriptor,
        output: NSMutableAttributedString
    ) {
        
        guard count > 0, let table = descriptor.tableContext else { return }
        let row = String(repeating: "\t", count: max(0, table.columnCount - 1)) + "\n"
        self.appendTableControl(String(repeating: row, count: count), descriptor: descriptor, output: output)
    }
    
    
    /// Appends a represented table cell without overwriting its inline font traits.
    static func appendTableCell(_ block: RenderedBlock, output: NSMutableAttributedString) {
        
        guard let table = block.descriptor.tableContext else { return }
        let cell = NSMutableAttributedString(attributedString: block.content)
        if table.isHeader, cell.length > 0 {
            var fontRuns: [(font: NSFont, range: NSRange)] = []
            cell.enumerateAttribute(.font, in: cell.fullRange) { value, range, _ in
                if let font = value as? NSFont {
                    fontRuns.append((font, range))
                }
            }
            for fontRun in fontRuns {
                cell.addAttribute(.font, value: self.font(fontRun.font, adding: [.bold]), range: fontRun.range)
            }
        }
        cell.addAttribute(.paragraphStyle, value: self.paragraphStyle(for: block.descriptor), range: cell.fullRange)
        output.append(cell)
    }
    
    
    /// Finishes the current table row and optionally inserts a paragraph break.
    static func finishTable(
        after descriptor: BlockDescriptor,
        addsBlankLine: Bool,
        output: NSMutableAttributedString
    ) {
        
        self.finishTableRow(after: descriptor, output: output)
        if addsBlankLine {
            self.appendTableControl("\n", descriptor: descriptor, output: output)
        }
    }
    
    
    /// Emits omitted trailing cells and terminates the current table row.
    static func finishTableRow(after descriptor: BlockDescriptor, output: NSMutableAttributedString) {
        
        guard let table = descriptor.tableContext else { return }
        let trailingCellCount = max(0, table.columnCount - table.column - 1)
        self.appendTableControl(
            String(repeating: "\t", count: trailingCellCount) + "\n",
            descriptor: descriptor,
            output: output
        )
    }
    
    
    /// Appends tabs and line breaks using the table's paragraph layout.
    static func appendTableControl(
        _ string: String,
        descriptor: BlockDescriptor,
        output: NSMutableAttributedString
    ) {
        
        var attributes = self.baseAttributes(font: descriptor.baseFont)
        attributes[.paragraphStyle] = self.paragraphStyle(for: descriptor)
        output.append(NSAttributedString(string: string, attributes: attributes))
    }
    
    
    /// Creates styled inline text for a Markdown run.
    static func inlineString(
        _ string: String,
        intent: InlinePresentationIntent?,
        link: URL?,
        baseFont: NSFont
    ) -> NSAttributedString {
        
        var traits = baseFont.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
        if intent?.contains(.stronglyEmphasized) == true { traits.insert(.bold) }
        if intent?.contains(.emphasized) == true { traits.insert(.italic) }
        let font: NSFont
        if intent?.contains(.code) == true {
            let monospacedFont = NSFont.monospacedSystemFont(ofSize: max(13, baseFont.pointSize - 1), weight: .regular)
            font = self.font(monospacedFont, adding: traits)
        } else {
            font = traits.isEmpty ? baseFont : self.font(baseFont, adding: traits)
        }
        
        var attributes = self.baseAttributes(font: font)
        if intent?.contains(.code) == true {
            attributes[.backgroundColor] = NSColor.controlBackgroundColor
        }
        if intent?.contains(.strikethrough) == true {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link, self.isAllowedExternalLink(link) {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        
        return NSAttributedString(string: string, attributes: attributes)
    }
    
    
    /// Returns the visible prefix for nested lists and quotations.
    static func prefix(for descriptor: BlockDescriptor, includesListMarker: Bool) -> String {
        
        var prefix = String(repeating: "│ ", count: descriptor.quoteDepth)
        if descriptor.listDepth > 0, includesListMarker {
            let marker = if descriptor.isOrderedList, let ordinal = descriptor.listOrdinal {
                "\(ordinal). "
            } else {
                "• "
            }
            prefix += marker
        }
        return prefix
    }
    
    
    /// Returns paragraph styling for the given Markdown block.
    static func paragraphStyle(
        for descriptor: BlockDescriptor,
        includesListMarker: Bool = true
    ) -> NSParagraphStyle {
        
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 10
        
        switch descriptor.kind {
            case .header(let level):
                style.paragraphSpacingBefore = level <= 2 ? 10 : 5
                style.paragraphSpacing = level <= 2 ? 14 : 10
            case .code:
                style.firstLineHeadIndent = 10
                style.headIndent = 10
                style.tailIndent = -10
                style.paragraphSpacingBefore = 4
                style.paragraphSpacing = 12
            case .tableCell(let table):
                style.tabStops = (1..<table.columnCount).map { column in
                    let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .left
                    let position = switch alignment {
                        case .center: CGFloat(column) + 0.5
                        case .right: CGFloat(column) + 1
                        default: CGFloat(column)
                    }
                    return NSTextTab(textAlignment: alignment, location: position * self.tableColumnWidth)
                }
                style.defaultTabInterval = self.tableColumnWidth
                style.paragraphSpacing = 6
            case .thematicBreak:
                style.paragraphSpacingBefore = 5
                style.paragraphSpacing = 12
            default:
                break
        }
        
        if descriptor.quoteDepth > 0 {
            style.headIndent = CGFloat(descriptor.quoteDepth) * 18
            style.firstLineHeadIndent = 0
        }
        if descriptor.listDepth > 0 {
            style.headIndent = CGFloat(descriptor.quoteDepth + descriptor.listDepth) * 24
            style.firstLineHeadIndent = includesListMarker
                ? CGFloat(descriptor.quoteDepth + descriptor.listDepth - 1) * 24
                : style.headIndent
        }
        
        return style
    }
    
    
    /// Returns standard preview attributes using dynamic system colors.
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }
    
    
    /// Returns the minimum wrapping width needed to preserve stable table columns.
    static func minimumContentWidth(for blocks: [RenderedBlock]) -> CGFloat {
        
        blocks.compactMap(\.descriptor.tableContext?.columnCount).max().map { columnCount in
            CGFloat(columnCount) * self.tableColumnWidth
        } ?? 0
    }
    
    
    /// Adds symbolic traits while preserving the supplied font's size and family.
    static func font(_ font: NSFont, adding traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
    
    
    /// Renders malformed Markdown as safe, readable source text.
    static func fallback(_ markdown: String) -> NSAttributedString {
        
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return NSAttributedString(
            string: markdown,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
    }
    
    
    /// Explains why an unusually large source document is not rendered.
    static func oversizedPreviewMessage() -> NSAttributedString {
        
        let message = String(
            localized: "MarkdownPreview.tooLarge",
            defaultValue: "Markdown preview is unavailable for documents larger than 128 KB.",
            table: "Document"
        )
        return NSAttributedString(string: message, attributes: self.baseAttributes(font: NSFont.systemFont(ofSize: 15)))
    }
}


private extension NSAttributedString {
    
    var fullRange: NSRange { NSRange(location: 0, length: self.length) }
}
