import SwiftUI

@main
struct MacFastApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacFast") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Atualizar estado") { model.refresh() }
                    .keyboardShortcut("r")
            }
        }
    }
}
