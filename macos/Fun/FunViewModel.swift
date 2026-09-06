import AppKit
import Foundation
import SwiftUI

@MainActor
final class FunViewModel: ObservableObject {
    @Published var snapshot = Snapshot(
        title: "Fun",
        usage: "0.0% of 500k",
        usageTip: "0 / 500000 last prompt tokens",
        working: false,
        loggedIn: false,
        empty: true,
        emptyNote: "Open a folder to start a chat.",
        thinking: "",
        steer: "",
        steerCount: "",
        rooms: [],
        items: [],
        queue: [],
        login: nil,
        toast: ""
    )
    @Published var draft: String = ""
    @Published var search: String = ""

    private var app: FunApp?
    private var bridge: DelegateBridge?

    var filteredRooms: [RoomInfo] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return snapshot.rooms }
        return snapshot.rooms.filter {
            $0.title.lowercased().contains(q)
                || $0.preview.lowercased().contains(q)
                || $0.workspace.lowercased().contains(q)
        }
    }

    func start() {
        guard app == nil else { return }
        let app = FunApp()
        let bridge = DelegateBridge(owner: self)
        self.app = app
        self.bridge = bridge
        app.start(delegate: bridge)
    }

    func stop() {
        app?.shutdown()
        app = nil
        bridge = nil
    }

    func submit() {
        let text = draft
        draft = ""
        app?.submit(text: text)
    }

    func interrupt() {
        let text = draft
        draft = ""
        app?.interrupt(text: text)
    }

    func abort() { app?.abort() }
    func openRoom(_ workspace: String) { app?.openRoom(workspace: workspace) }
    func newChat() { app?.newChat() }
    func removeFolder() { app?.removeFolder() }
    func loginGrok() { app?.loginGrok() }
    func logoutGrok() { app?.logoutGrok() }
    func dismissLogin() { app?.dismissLogin() }
    func dismissToast() { app?.dismissToast() }

    func queueSendNow(_ i: UInt32) { app?.queueSendNow(index: i) }
    func queueDrop(_ i: UInt32) { app?.queueDrop(index: i) }
    func queueMove(_ i: UInt32, delta: Int32) { app?.queueMove(index: i, delta: delta) }
    func queueEdit(_ i: UInt32) {
        guard let text = app?.queueEdit(index: i), !text.isEmpty else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        } else {
            draft = "\(draft.trimmingCharacters(in: .whitespacesAndNewlines))\n\(text)"
        }
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Open folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app?.addFolder(workspace: url.path)
    }

    fileprivate func handleSnapshot(_ snap: Snapshot) {
        snapshot = snap
        if let login = snap.login, !login.openUrl.isEmpty, login.userCode != lastOpenedCode {
            lastOpenedCode = login.userCode
            if let url = URL(string: login.openUrl) {
                NSWorkspace.shared.open(url)
            }
        }
        if snap.login == nil { lastOpenedCode = "" }
    }

    private var lastOpenedCode = ""
}

private final class DelegateBridge: FunDelegate {
    private weak var owner: FunViewModel?

    init(owner: FunViewModel) { self.owner = owner }

    func onSnapshot(snapshot: Snapshot) {
        let owner = self.owner
        Task { @MainActor in owner?.handleSnapshot(snapshot) }
    }
}
