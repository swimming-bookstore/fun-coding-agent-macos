import AppKit
import Foundation
import UniformTypeIdentifiers

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
    @Published var images: [ImageAttachment] = []
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
        if let model = UserDefaults.standard.string(forKey: "fun.model") {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                app.setModel(model: trimmed)
            }
        }
    }

    func stop() {
        app?.shutdown()
        app = nil
        bridge = nil
    }

    func submit() {
        let text = draft
        let attached = images
        draft = ""
        images = []
        app?.submit(text: text, images: attached)
    }

    func interrupt() {
        let text = draft
        let attached = images
        draft = ""
        images = []
        app?.interrupt(text: text, images: attached)
    }

    func abort() { app?.abort() }
    func openRoom(_ workspace: String) { app?.openRoom(workspace: workspace) }
    func newChat() { app?.newChat() }
    func removeFolder(_ workspace: String) { app?.removeFolder(workspace: workspace) }
    func loginGrok() { app?.loginGrok() }
    func logoutGrok() { app?.logoutGrok() }
    func dismissLogin() { app?.dismissLogin() }
    func dismissToast() { app?.dismissToast() }
    func setModel(_ model: String) { app?.setModel(model: model) }

    func queueSendNow(_ i: UInt32) { app?.queueSendNow(index: i) }
    func queueDrop(_ i: UInt32) { app?.queueDrop(index: i) }
    func queueMove(_ i: UInt32, delta: Int32) { app?.queueMove(index: i, delta: delta) }
    func queueEdit(_ i: UInt32) {
        guard let turn = app?.queueEdit(index: i) else { return }
        let text = turn.text
        let attached = turn.images
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty {
            return
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = text
        } else if !text.isEmpty {
            draft = "\(draft.trimmingCharacters(in: .whitespacesAndNewlines))\n\(text)"
        }
        images.append(contentsOf: attached)
    }

    func attachImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Attach images"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attachFile(url)
        }
    }

    func attachFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        images.append(ImageAttachment(name: url.lastPathComponent, data: data))
    }

    func dropImage(_ index: Int) {
        guard images.indices.contains(index) else { return }
        images.remove(at: index)
    }

    func takeDrop(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                took = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { return }
                    Task { @MainActor in self.attachFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                took = true
                provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data, !data.isEmpty else { return }
                    Task { @MainActor in
                        self.images.append(ImageAttachment(name: "image", data: data))
                    }
                }
            }
        }
        return took
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Open folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFolder(url.path)
    }

    func addFolder(_ path: String) {
        app?.addFolder(workspace: path)
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

private final class DelegateBridge: FunDelegate, @unchecked Sendable {
    private let hop: @Sendable (Snapshot) -> Void

    init(owner: FunViewModel) {
        hop = { [weak owner] snapshot in
            Task { @MainActor in owner?.handleSnapshot(snapshot) }
        }
    }

    func onSnapshot(snapshot: Snapshot) {
        hop(snapshot)
    }
}
