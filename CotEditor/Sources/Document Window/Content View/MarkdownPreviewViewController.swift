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
import Combine
import SwiftUI
import WebKit

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


@MainActor private final class MarkdownPreviewViewController: NSViewController {
    
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
    private let model = MarkdownPreviewModel()
    private let renderer = MarkdownPreviewRenderer()
    
    private lazy var updateDebouncer = Debouncer(delay: .milliseconds(200)) { [weak self] in
        self?.renderPreview()
    }
    
    private var textStorageObserver: any NSObjectProtocol?
    private var renderTask: Task<Void, Never>?
    
    
    // MARK: Lifecycle
    
    init(document: Document) {
        
        self.document = document
        
        super.init(nibName: nil, bundle: nil)
    }
    
    
    required init?(coder: NSCoder) {
        
        fatalError("init(coder:) has not been implemented")
    }
    
    
    isolated deinit {
        if let textStorageObserver = self.textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
        self.renderTask?.cancel()
    }
    
    
    override func loadView() {
        
        let view = MarkdownPreviewView(model: self.model)
        self.view = NSHostingView(rootView: view)
    }
    
    
    // MARK: Private Methods
    
    /// Starts observing document changes and renders the current contents immediately.
    private func startUpdating() {
        
        guard self.textStorageObserver == nil else { return }
        
        self.textStorageObserver = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: self.document.textStorage,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard
                    let textStorage = notification.object as? NSTextStorage,
                    textStorage.editedMask.contains(.editedCharacters)
                else { return }
                
                self?.updateDebouncer.schedule()
            }
        }
        self.renderPreview()
    }
    
    
    /// Stops observing the document and cancels pending rendering work.
    private func stopUpdating() {
        
        if let textStorageObserver = self.textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
            self.textStorageObserver = nil
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
            guard let html = await renderer.render(markdown: source) else { return }
            
            guard !Task.isCancelled, let self, self.isPreviewActive else { return }
            
            self.model.html = html
            self.renderTask = nil
        }
    }
}


private actor MarkdownPreviewRenderer {
    
    /// Serializes background rendering so stale large-document renders never overlap.
    func render(markdown: String) -> String? {
        
        guard !Task.isCancelled else { return nil }
        
        let html = MarkdownHTMLRenderer.render(markdown: markdown)
        
        return Task.isCancelled ? nil : html
    }
}


@MainActor private final class MarkdownPreviewModel: ObservableObject {
    
    @Published var html = MarkdownHTMLRenderer.render(markdown: "")
}


private struct MarkdownPreviewView: View {
    
    @ObservedObject var model: MarkdownPreviewModel
    
    
    var body: some View {
        
        MarkdownWebView(html: self.model.html)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


private struct MarkdownWebView: NSViewRepresentable {
    
    var html: String
    
    
    func makeCoordinator() -> Coordinator {
        
        Coordinator()
    }
    
    
    func makeNSView(context: Context) -> WKWebView {
        
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityIdentifier("MarkdownPreviewWebView")
        
        return webView
    }
    
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        
        guard
            self.html != context.coordinator.loadedHTML
        else { return }
        
        context.coordinator.loadedHTML = self.html
        context.coordinator.load(self.html, in: webView)
    }
    
    
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        
        var loadedHTML: String?
        private var loadGeneration = 0
        private var scrollCaptureTask: Task<Void, Never>?
        private var scrollRestoreTask: Task<Void, Never>?
        private var pendingNavigation: WKNavigation?
        private var scrollFraction: Double?
        
        
        /// Loads updated preview HTML while preserving the reader's relative scroll position.
        func load(_ html: String, in webView: WKWebView) {
            
            self.loadGeneration += 1
            let generation = self.loadGeneration
            self.scrollCaptureTask?.cancel()
            self.scrollRestoreTask?.cancel()
            
            guard webView.url != nil else {
                self.pendingNavigation = webView.loadHTMLString(html, baseURL: nil)
                return
            }
            
            self.scrollCaptureTask = Task { [weak self, weak webView] in
                guard let self, let webView else { return }
                
                let value = try? await webView.callAsyncJavaScript(
                    "return window.scrollY / Math.max(1, document.documentElement.scrollHeight - window.innerHeight);",
                    in: nil,
                    contentWorld: .defaultClient
                )
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                
                self.scrollFraction = (value as? NSNumber)?.doubleValue
                self.pendingNavigation = webView.loadHTMLString(html, baseURL: nil)
                self.scrollCaptureTask = nil
            }
        }
        
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            
            guard navigation === self.pendingNavigation else { return }
            
            self.pendingNavigation = nil
            guard let scrollFraction else { return }
            
            self.scrollFraction = nil
            let generation = self.loadGeneration
            self.scrollRestoreTask = Task { [weak self, weak webView] in
                guard let self, let webView, generation == self.loadGeneration else { return }
                
                _ = try? await webView.callAsyncJavaScript(
                    "window.scrollTo(0, fraction * Math.max(0, document.documentElement.scrollHeight - window.innerHeight));",
                    arguments: ["fraction": scrollFraction],
                    in: nil,
                    contentWorld: .defaultClient
                )
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                
                self.scrollRestoreTask = nil
            }
        }
        
        
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            
            guard navigationAction.navigationType == .linkActivated else {
                guard let url = navigationAction.request.url else { return .allow }
                
                return url.absoluteString == "about:blank" ? .allow : .cancel
            }
            
            guard let url = navigationAction.request.url else {
                return .cancel
            }
            
            if MarkdownHTMLRenderer.isAllowedExternalLink(url) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}
