import SwiftUI

// O ponto de entrada fica em `main.swift` chamando `main()` à mão, em vez de
// `@main`. Com `@main` num executável, o SwiftPM procura um símbolo de entrada
// que não é emitido quando o pacote é compilado com testes habilitados, e o
// link de `swift test` falha com `_MacFastApp_main` indefinido.
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

MacFastApp.main()
