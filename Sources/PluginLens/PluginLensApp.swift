import SwiftUI

@main
struct PluginLensApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Plugin Lens") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.chooseProject() }
                    .keyboardShortcut("o")
            }
        }
    }
}
