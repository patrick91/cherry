import CherryMobileKit
import SwiftUI

@main
struct CherryMobileApp: App {
    @State private var model = AppModel(launch: .current)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
    }
}
