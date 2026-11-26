//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import AppKit
import SwiftUI

/// The window's two columns, in AppKit.
///
/// `NavigationSplitView` insists on its own sidebar button, in its own place, and
/// `toolbar(removing:)` does not take it away. Every screen here is drawn from the
/// tokens, so the container is too.
struct NectoSplitView<Sidebar: View, Detail: View>: NSViewControllerRepresentable {
    let sidebar: Sidebar
    let detail: Detail

    func makeNSViewController(context: Context) -> Controller {
        Controller(sidebar: sidebar, detail: detail)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.sidebarHost.rootView = sidebar
        controller.detailHost.rootView = detail
    }

    final class Controller: NSSplitViewController {
        let sidebarHost: NSHostingController<Sidebar>
        let detailHost: NSHostingController<Detail>

        init(sidebar: Sidebar, detail: Detail) {
            sidebarHost = NSHostingController(rootView: sidebar)
            detailHost = NSHostingController(rootView: detail)
            super.init(nibName: nil, bundle: nil)

            // Both columns draw their own title bar row, so neither wants AppKit's inset
            // for one. Without this the row starts below the traffic lights instead of
            // beside them.
            sidebarHost.safeAreaRegions = []
            detailHost.safeAreaRegions = []

            // `.sidebar` behaviour would bring AppKit's translucent material and its own
            // ideas about the title bar. A plain item is a plain column.
            let sidebarItem = NSSplitViewItem(viewController: sidebarHost)
            sidebarItem.minimumThickness = 240
            sidebarItem.maximumThickness = 420
            sidebarItem.canCollapse = false
            sidebarItem.holdingPriority = .defaultLow

            let detailItem = NSSplitViewItem(viewController: detailHost)
            detailItem.minimumThickness = 420

            addSplitViewItem(sidebarItem)
            addSplitViewItem(detailItem)
        }

        /// Dragging the divider past the minimum used to collapse the sidebar, and the
        /// button's idea of whether it was open then disagreed with reality — which is
        /// how the traffic lights ended up on top of the heading. The divider now only
        /// resizes; the button is the only thing that closes it.
        override func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            guard !hasPlacedDivider else { return }
            hasPlacedDivider = true
            // The list installs its scroller after appearing. Place the divider after
            // that pass so the scroller's intrinsic width cannot move the 280pt default.
            DispatchQueue.main.async { [weak self] in
                self?.splitView.setPosition(280, ofDividerAt: 0)
            }
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            if tableStyleObservation == nil {
                configureSidebarList(in: sidebarHost.view)
            }
            configureSidebarScrollerIfNeeded()
        }

        private func configureSidebarList(in view: NSView) {
            if let scrollView = view as? NSScrollView,
               let table = scrollView.documentView as? NSTableView {
                sidebarScrollView = scrollView
                // Let AppKit choose the List's scroller style. Forcing overlay
                // scrollbars can re-enter disclosure row layout in an overflowing List.
                scrollerStyleObservation = scrollView.observe(\.scrollerStyle, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.scheduleSidebarScrollerUpdate()
                    }
                }
                // SwiftUI's plain List uses AppKit's fullWidth style, which adds
                // padding outside the row's own insets. Settings has only our insets.
                tableStyleObservation = table.observe(\.style, options: [.initial, .new]) { table, _ in
                    MainActor.assumeIsolated {
                        if table.style != .plain {
                            table.style = .plain
                        }
                        table.intercellSpacing.width = 0
                    }
                }
                if let outline = table as? NSOutlineView {
                    DispatchQueue.main.async { [weak outline] in
                        guard let outline, outline.indentationPerLevel != 8 else { return }
                        outline.indentationPerLevel = 8
                    }
                }
                return
            }
            for child in view.subviews where tableStyleObservation == nil {
                configureSidebarList(in: child)
            }
        }

        private func configureSidebarScrollerIfNeeded() {
            guard let scrollView = sidebarScrollView, scrollView.scrollerStyle == .legacy,
                  scrollView.hasVerticalScroller, let scroller = scrollView.verticalScroller,
                  scrollView.autohidesScrollers || scroller.controlSize != .small else { return }
            scheduleSidebarScrollerUpdate()
        }

        private func scheduleSidebarScrollerUpdate() {
            guard !sidebarScrollerUpdatePending, let scrollView = sidebarScrollView else { return }
            sidebarScrollerUpdatePending = true
            // SwiftUI can restore List's scroller settings while updating the rows.
            // Keep the legacy gutter stable without changing AppKit's chosen style.
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self else { return }
                defer { sidebarScrollerUpdatePending = false }
                guard let scrollView, scrollView.scrollerStyle == .legacy, scrollView.hasVerticalScroller,
                      let scroller = scrollView.verticalScroller else { return }
                let needsSmall = scroller.controlSize != .small
                let needsGutter = scrollView.autohidesScrollers
                guard needsSmall || needsGutter else { return }
                if needsSmall {
                    scroller.controlSize = .small
                }
                if needsGutter {
                    scrollView.autohidesScrollers = false
                }
                // The installed scroller can still have its old frame.
                scrollView.tile()
            }
        }

        private weak var sidebarScrollView: NSScrollView?
        private var sidebarScrollerUpdatePending = false
        private var scrollerStyleObservation: NSKeyValueObservation?
        private var tableStyleObservation: NSKeyValueObservation?
        private var hasPlacedDivider = false

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }
    }
}
