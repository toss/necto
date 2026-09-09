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

        private var hasPlacedDivider = false

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }
    }
}
