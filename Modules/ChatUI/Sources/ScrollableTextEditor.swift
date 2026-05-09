import AppKit
import SwiftUI

enum ScrollableTextEditorFontStyle {
    case body
    case monospacedBody

    fileprivate var nsFont: NSFont {
        switch self {
        case .body:
            return NSFont.preferredFont(forTextStyle: .body)
        case .monospacedBody:
            let bodyFont = NSFont.preferredFont(forTextStyle: .body)
            return NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
        }
    }
}

@MainActor
enum MCPJSONEditorConfiguration {
    static func configure(scrollView: NSScrollView, textView: NSTextView) {
        ScrollableTextEditorConfiguration.configure(
            scrollView: scrollView,
            textView: textView,
            wrapLines: false,
            showsHorizontalScroller: true
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
    }
}

@MainActor
private enum ScrollableTextEditorConfiguration {
    static func configure(
        scrollView: NSScrollView,
        textView: NSTextView,
        wrapLines: Bool,
        showsHorizontalScroller: Bool
    ) {
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = showsHorizontalScroller && !wrapLines

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapLines
        textView.autoresizingMask = wrapLines ? [.width] : [.height]

        guard let textContainer = textView.textContainer else {
            return
        }

        textContainer.heightTracksTextView = false
        if wrapLines {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(
                width: max(scrollView.contentSize.width, 1),
                height: .greatestFiniteMagnitude
            )
        } else {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

@MainActor
struct ScrollableTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontStyle: ScrollableTextEditorFontStyle
    let wrapLines: Bool
    let showsHorizontalScroller: Bool
    let configureEditor: (@MainActor (NSScrollView, NSTextView) -> Void)?

    init(
        text: Binding<String>,
        fontStyle: ScrollableTextEditorFontStyle = .body,
        wrapLines: Bool = true,
        showsHorizontalScroller: Bool = false,
        configureEditor: (@MainActor (NSScrollView, NSTextView) -> Void)? = nil
    ) {
        _text = text
        self.fontStyle = fontStyle
        self.wrapLines = wrapLines
        self.showsHorizontalScroller = showsHorizontalScroller
        self.configureEditor = configureEditor
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = fontStyle.nsFont

        ScrollableTextEditorConfiguration.configure(
            scrollView: scrollView,
            textView: textView,
            wrapLines: wrapLines,
            showsHorizontalScroller: showsHorizontalScroller
        )
        configureEditor?(scrollView, textView)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }

        if textView.string != text {
            textView.string = text
        }
        textView.font = fontStyle.nsFont

        ScrollableTextEditorConfiguration.configure(
            scrollView: nsView,
            textView: textView,
            wrapLines: wrapLines,
            showsHorizontalScroller: showsHorizontalScroller
        )
        configureEditor?(nsView, textView)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScrollableTextEditor

        init(parent: ScrollableTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
        }
    }
}