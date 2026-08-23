//
//  MarkdownPreviewViewController.swift
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

final class DocumentContentViewController: NSSplitViewController {
    
    // MARK: Public Properties
    
    let editorViewController: DocumentViewController
    
    private(set) var showsMarkdownPreview = false
    
    
    // MARK: Private Properties
    
    private let document: Document
    
    private var previewViewController: MarkdownPreviewViewController?
    private var previewViewItem: NSSplitViewItem?
    private var didSetInitialPreviewPosition = false
    
    
    // MARK: Lifecycle
    
    init(document: Document) {
        
        self.document = document
        self.editorViewController = DocumentViewController(document: document)
        
        super.init(nibName: nil, bundle: nil)
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        self.splitView.isVertical = true
        self.splitView.dividerStyle = .thin
        
        let editorViewItem = NSSplitViewItem(viewController: self.editorViewController)
        editorViewItem.minimumThickness = 200
        self.addSplitViewItem(editorViewItem)
    }
    
    
    // MARK: Public Methods
    
    /// Shows or hides the live Markdown preview beside the editor.
    ///
    /// - Parameter visible: Whether the preview should be visible.
    func setMarkdownPreviewVisible(_ visible: Bool) {
        
        guard visible != self.showsMarkdownPreview else { return }
        
        if visible {
            let previewViewItem = self.preparePreviewViewItem()
            
            self.showsMarkdownPreview = true
            self.previewViewController?.isPreviewActive = true
            previewViewItem.isCollapsed = false
            
            if !self.didSetInitialPreviewPosition, self.splitView.bounds.width > 0 {
                self.splitView.setPosition(self.splitView.bounds.midX, ofDividerAt: 0)
                self.didSetInitialPreviewPosition = true
            }
            
        } else {
            self.showsMarkdownPreview = false
            self.previewViewItem?.isCollapsed = true
            self.previewViewController?.isPreviewActive = false
            
            if let textView = self.editorViewController.focusedTextView {
                self.view.window?.makeFirstResponder(textView)
            }
        }
    }
    
    
    // MARK: Private Methods
    
    /// Creates the preview pane on demand and returns its split view item.
    private func preparePreviewViewItem() -> NSSplitViewItem {
        
        if let previewViewItem = self.previewViewItem {
            return previewViewItem
        }
        
        let previewViewController = MarkdownPreviewViewController(document: self.document)
        let previewViewItem = NSSplitViewItem(viewController: previewViewController)
        previewViewItem.canCollapse = false
        previewViewItem.isCollapsed = true
        previewViewItem.minimumThickness = 240
        
        self.addSplitViewItem(previewViewItem)
        self.previewViewController = previewViewController
        self.previewViewItem = previewViewItem
        
        return previewViewItem
    }
}


enum MarkdownPreviewLayout {
    
    /// Returns a wrapping width that fits ordinary prose while keeping table columns stable.
    static func documentWidth(viewportWidth: CGFloat, minimumContentWidth: CGFloat, horizontalInset: CGFloat) -> CGFloat {
        
        max(viewportWidth, minimumContentWidth + horizontalInset * 2)
    }
}


@MainActor private final class MarkdownPreviewViewController: NSViewController, NSTextViewDelegate {
    
    // MARK: Public Properties
    
    var isPreviewActive = false {
        
        didSet {
            guard isPreviewActive != oldValue else { return }
            
            if isPreviewActive {
                self.startUpdating()
            } else {
                self.stopUpdating()
            }
        }
    }
    
    
    // MARK: Private Properties
    
    private let document: Document
    private let renderer = MarkdownPreviewRenderer()
    private lazy var textView: NSTextView = {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 32, height: 32)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = self
        textView.setAccessibilityIdentifier("MarkdownPreviewTextView")
        let accessibilityLabel = String(
            localized: "Toolbar.markdownPreview.label",
            defaultValue: "Markdown Preview",
            table: "Document"
        )
        textView.setAccessibilityLabel(accessibilityLabel)
        
        return textView
    }()
    private lazy var scrollView: NSScrollView = {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = self.textView
        scrollView.setAccessibilityIdentifier("MarkdownPreviewView")
        
        return scrollView
    }()
    
    private lazy var updateDebouncer = Debouncer(delay: .milliseconds(200)) { [weak self] in
        self?.renderPreview()
    }
    
    private var isObservingTextStorage = false
    private var renderTask: Task<Void, Never>?
    private var minimumContentWidth: CGFloat = 0
    
    
    // MARK: Lifecycle
    
    init(document: Document) {
        
        self.document = document
        
        super.init(nibName: nil, bundle: nil)
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        self.renderTask?.cancel()
    }
    
    
    override func loadView() {
        
        self.view = self.scrollView
    }
    
    
    override func viewDidLayout() {
        
        super.viewDidLayout()
        self.updateDocumentWidth()
    }
    
    
    // MARK: Private Methods
    
    /// Starts observing document changes and renders the current contents immediately.
    private func startUpdating() {
        
        guard !self.isObservingTextStorage else { return }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(markdownPreviewTextStorageDidProcessEditing),
            name: NSTextStorage.didProcessEditingNotification,
            object: self.document.textStorage
        )
        self.isObservingTextStorage = true
        self.renderPreview()
    }
    
    
    /// Schedules rendering only for character edits, not syntax-color attribute changes.
    @objc private func markdownPreviewTextStorageDidProcessEditing(_ notification: Notification) {
        
        guard
            let textStorage = notification.object as? NSTextStorage,
            textStorage.editedMask.contains(.editedCharacters)
        else { return }
        
        self.updateDebouncer.schedule()
    }
    
    
    /// Stops observing the document and cancels pending rendering work.
    private func stopUpdating() {
        
        if self.isObservingTextStorage {
            NotificationCenter.default.removeObserver(
                self,
                name: NSTextStorage.didProcessEditingNotification,
                object: self.document.textStorage
            )
            self.isObservingTextStorage = false
        }
        self.updateDebouncer.cancel()
        self.renderTask?.cancel()
        self.renderTask = nil
    }
    
    
    /// Renders a snapshot of the document without blocking typing.
    private func renderPreview() {
        
        let source = self.document.textStorage.string
        let renderer = self.renderer
        
        self.renderTask?.cancel()
        self.renderTask = Task { [weak self] in
            guard let rendering = await renderer.render(markdown: source) else { return }
            
            guard !Task.isCancelled, let self, self.isPreviewActive else { return }
            
            self.display(rendering)
            self.renderTask = nil
        }
    }
    
    
    /// Replaces the preview contents without forcing whole-document layout on the main actor.
    private func display(_ rendering: MarkdownPreviewRendering) {
        
        let contentView = self.scrollView.contentView
        let scrollOrigin = contentView.bounds.origin
        
        self.minimumContentWidth = rendering.minimumContentWidth
        self.updateDocumentWidth()
        self.textView.textStorage?.setAttributedString(rendering.attributedString)
        contentView.scroll(to: scrollOrigin)
        self.scrollView.reflectScrolledClipView(contentView)
    }
    
    
    /// Keeps prose wrapped to the viewport while allowing wide Markdown tables to scroll horizontally.
    private func updateDocumentWidth() {
        
        let width = MarkdownPreviewLayout.documentWidth(
            viewportWidth: self.scrollView.contentSize.width,
            minimumContentWidth: self.minimumContentWidth,
            horizontalInset: self.textView.textContainerInset.width
        )
        guard abs(self.textView.frame.width - width) > 0.5 else { return }
        
        self.textView.setFrameSize(NSSize(width: width, height: self.textView.frame.height))
    }
    
    
    // MARK: NSTextViewDelegate
    
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at characterIndex: Int) -> Bool {
        
        let url: URL? = switch link {
            case let url as URL: url
            case let string as String: URL(string: string)
            default: nil
        }
        guard let url, MarkdownAttributedStringRenderer.isAllowedExternalLink(url) else { return true }
        
        NSWorkspace.shared.open(url)
        return true
    }
}


private actor MarkdownPreviewRenderer {
    
    /// Serializes background rendering so stale large-document renders never overlap.
    func render(markdown: String) -> sending MarkdownPreviewRendering? {
        
        guard !Task.isCancelled else { return nil }
        
        let rendering = MarkdownAttributedStringRenderer.render(markdown: markdown)
        
        return Task.isCancelled ? nil : rendering
    }
}
