import SwiftUI
import UIKit

@main
struct LlamaSwapApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class BGTaskHandle {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }

    deinit { end() }
}
