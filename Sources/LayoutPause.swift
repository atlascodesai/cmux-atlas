import AppKit
import SwiftUI

/// A view modifier that pauses AppKit layout traversal for inactive views.
///
/// When `isPaused` is true, the modifier finds the ForEach iteration container
/// NSView and sets `isHidden = true` on it. This causes AppKit's
/// `_layoutSubtreeIfNeeded` to skip the entire subtree, dramatically reducing
/// main thread layout cost when many workspace views are stacked in a ZStack.
///
/// When `isPaused` becomes false, the container is unhidden and marked as
/// needing layout so it picks up any geometry changes that occurred while paused.
struct LayoutPauseModifier: ViewModifier {
    let isPaused: Bool

    func body(content: Content) -> some View {
        content
            .background(LayoutPauseHelper(isPaused: isPaused))
    }
}

extension View {
    /// Pause AppKit layout traversal for this view's subtree.
    ///
    /// Use this on views inside a ZStack that are toggled via opacity rather
    /// than removed from the hierarchy. Unlike `opacity(0)`, pausing layout
    /// prevents AppKit from walking the hidden subtree on every frame.
    func layoutPaused(_ paused: Bool) -> some View {
        modifier(LayoutPauseModifier(isPaused: paused))
    }
}

private struct LayoutPauseHelper: NSViewRepresentable {
    let isPaused: Bool

    func makeNSView(context: Context) -> LayoutPauseNSView {
        let view = LayoutPauseNSView()
        view.alphaValue = 0
        view.frame = .zero
        return view
    }

    func updateNSView(_ nsView: LayoutPauseNSView, context: Context) {
        nsView.updatePauseState(isPaused)
    }
}

final class LayoutPauseNSView: NSView {
    private weak var container: NSView?
    private var lastPaused: Bool?

    func updatePauseState(_ isPaused: Bool) {
        guard isPaused != lastPaused else { return }
        lastPaused = isPaused

        if container == nil {
            container = findContainer()
        }

        guard let container else { return }

        if isPaused {
            container.isHidden = true
        } else {
            container.isHidden = false
            container.needsLayout = true
        }
    }

    /// Find the ForEach iteration container NSView.
    ///
    /// The `.background()` modifier creates a container with exactly 2 children
    /// (content + background). We need to skip that and find the parent used by
    /// the ZStack/ForEach level so hiding blocks layout traversal for the whole
    /// workspace subtree.
    private func findContainer() -> NSView? {
        var current: NSView? = self.superview
        while let view = current {
            if let parent = view.superview,
               parent.subviews.count > 2 {
                return view
            }
            current = view.superview
        }

        current = self.superview
        var skippedFirst = false
        while let view = current {
            if let parent = view.superview,
               parent.subviews.count > 1 {
                if !skippedFirst {
                    skippedFirst = true
                    current = view.superview
                    continue
                }
                return view
            }
            current = view.superview
        }

        return nil
    }
}
