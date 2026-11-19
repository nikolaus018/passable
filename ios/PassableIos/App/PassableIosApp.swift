import PassableKit
import SwiftUI

@main
struct PassableIosApp: App {
    var body: some Scene {
        WindowGroup {
            PassableRootView()
                // A .passablemix opened from Files, AirDrop or Mail.
                .onOpenURL { url in PassableRootView.open(url) }
        }
    }
}
