import SwiftUI

@main
struct WheelNotesApp: App {
    @NSApplicationDelegateAdaptor(WheelNotesAppDelegate.self) private var appDelegate
    @State private var model = WheelNotesModel()

    var body: some Scene {
        WindowGroup {
            WheelNotesRootView(model: model)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .windowStyle(.titleBar)
    }
}
