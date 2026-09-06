import SwiftUI

@main
struct FunMacApp: App {
    @StateObject private var viewModel = FunViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { viewModel.pickFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("New Chat") { viewModel.newChat() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                if viewModel.snapshot.loggedIn {
                    Button("Log Out of Grok") { viewModel.logoutGrok() }
                } else {
                    Button("Log In to Grok") { viewModel.loginGrok() }
                }
            }
        }
    }
}
