//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import SwiftUI
import UIKit

struct ControlFixture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: ControlFixtureController())
    }
    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
