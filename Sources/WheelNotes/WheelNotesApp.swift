import SwiftUI

@main
struct WheelNotesApp: App {
    @State private var model = WheelNotesModel()

    var body: some Scene {
        WindowGroup {
            WheelNotesRootView(model: model)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .windowStyle(.titleBar)
    }
}
