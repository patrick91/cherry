import CherryMobileKit
import SwiftUI

@main
struct CherryMobileApp: App {
    @State private var model = AppModel(launch: .current)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.didBecomeActive() }
            case .background: model.didEnterBackground()
            default: break
            }
        }
    }
}
