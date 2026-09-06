import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: FunViewModel

    var body: some View {
        NavigationSplitView {
            Sidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            ThreadView(viewModel: viewModel)
                .navigationTitle(viewModel.snapshot.empty ? "Fun" : viewModel.snapshot.title)
                .navigationSubtitle(viewModel.snapshot.empty ? "" : viewModel.snapshot.usage)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(role: .destructive) {
                    viewModel.removeFolder()
                } label: {
                    Label("Remove Folder", systemImage: "folder.badge.minus")
                }
                .help("Remove Folder")
                .disabled(viewModel.snapshot.empty)
            }
            if viewModel.snapshot.working {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel", role: .destructive) { viewModel.abort() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat")
                .disabled(viewModel.snapshot.empty)
            }
        }
        .task { viewModel.start() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            viewModel.stop()
        }
        .sheet(item: loginBinding) { login in
            LoginSheet(login: login, onCancel: { viewModel.dismissLogin() })
        }
        .alert(
            "Grok",
            isPresented: Binding(
                get: { !viewModel.snapshot.toast.isEmpty },
                set: { if !$0 { viewModel.dismissToast() } }
            )
        ) {
            Button("OK") { viewModel.dismissToast() }
        } message: {
            Text(viewModel.snapshot.toast)
        }
    }

    private var loginBinding: Binding<LoginInfo?> {
        Binding(
            get: { viewModel.snapshot.login },
            set: { if $0 == nil { viewModel.dismissLogin() } }
        )
    }
}

private struct Sidebar: View {
    @ObservedObject var viewModel: FunViewModel

    var body: some View {
        List(selection: selection) {
            ForEach(viewModel.filteredRooms, id: \.workspace) { room in
                RoomRowView(room: room)
                    .tag(room.workspace)
                    .contextMenu {
                        Button("New Chat") { viewModel.newChat() }
                        Divider()
                        Button("Remove Folder", role: .destructive) { viewModel.removeFolder() }
                    }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $viewModel.search, placement: .sidebar, prompt: "Search")
        .navigationTitle("Fun")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.pickFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder.badge.plus")
                }
                .help("Open Folder")
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { viewModel.snapshot.rooms.first { $0.selected }?.workspace },
            set: { if let path = $0 { viewModel.openRoom(path) } }
        )
    }
}

private struct RoomRowView: View {
    let room: RoomInfo

    var body: some View {
        HStack(spacing: 10) {
            statusMark(working: room.working, error: room.error, done: room.done)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.title).lineLimit(1)
                Text(room.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if room.unread > 0 {
                Text("\(room.unread)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct ThreadView: View {
    @ObservedObject var viewModel: FunViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.snapshot.items, id: \.id) { item in
                            ChatItemView(item: item).id(item.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: viewModel.snapshot.items.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if !viewModel.snapshot.thinking.isEmpty {
                Dock(title: "Thinking") {
                    Text(viewModel.snapshot.thinking)
                        .italic()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(6)
                }
            }
            if !viewModel.snapshot.steer.isEmpty {
                Dock(title: "Send Now") {
                    HStack {
                        Text(viewModel.snapshot.steer).lineLimit(1)
                        Spacer()
                        if !viewModel.snapshot.steerCount.isEmpty {
                            Text(viewModel.snapshot.steerCount)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !viewModel.snapshot.queue.isEmpty {
                Dock(title: "Queue") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.snapshot.queue, id: \.index) { item in
                            QueueRow(item: item, total: viewModel.snapshot.queue.count, viewModel: viewModel)
                        }
                    }
                }
            }
            Composer(viewModel: viewModel)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct Dock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let total: Int
    @ObservedObject var viewModel: FunViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(oneLine(item.text))
                .lineLimit(1)
                .help(item.text)
            Spacer(minLength: 8)
            Button("Send Now") { viewModel.queueSendNow(item.index) }
            Button("Edit") { viewModel.queueEdit(item.index) }
            Button("Move Up") { viewModel.queueMove(item.index, delta: -1) }
                .disabled(item.index == 0)
            Button("Move Down") { viewModel.queueMove(item.index, delta: 1) }
                .disabled(Int(item.index) + 1 >= total)
            Button("Cancel", role: .destructive) { viewModel.queueDrop(item.index) }
        }
        .padding(6)
        .background(item.flash ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .controlSize(.small)
    }
}

private struct Composer: View {
    @ObservedObject var viewModel: FunViewModel
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !viewModel.snapshot.empty
            && !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onKeyPress { press in
                        if press.key == .escape {
                            viewModel.abort()
                            return .handled
                        }
                        guard press.key == .return else { return .ignored }
                        if press.modifiers.contains(.option) { return .ignored }
                        if press.modifiers.contains(.control) {
                            viewModel.interrupt()
                            return .handled
                        }
                        viewModel.submit()
                        return .handled
                    }
                Button("Send") { viewModel.submit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSend)
                    .help("Return to send  ·  Control-Return interrupt  ·  Option-Return newline")
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
    }
}

private struct ChatItemView: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 2) {
                Text("You")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.body)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .agent:
            VStack(alignment: .leading, spacing: 2) {
                Text("Fun")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    if item.streaming {
                        Text(item.body)
                    } else {
                        Text(markdown(item.body))
                    }
                }
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            Text(item.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        case .tool:
            DisclosureGroup(item.toolSummary) {
                Text(item.toolDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .foregroundStyle(.secondary)
        case .marker:
            HStack {
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                Text("New Messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
            }
        }
    }
}

private struct LoginSheet: View {
    let login: LoginInfo
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with SuperGrok or X Premium")
                .font(.headline)
            Text(login.status)
                .textSelection(.enabled)
            if !login.userCode.isEmpty {
                Text(login.userCode)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
            }
            if !login.uri.isEmpty {
                Text(login.uri)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

extension LoginInfo: Identifiable {
    public var id: String { userCode + status }
}

@ViewBuilder
private func statusMark(working: Bool, error: Bool, done: Bool) -> some View {
    if working {
        ProgressView().controlSize(.small)
    } else if done {
        Image(systemName: "checkmark")
            .foregroundStyle(.secondary)
    } else if error {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
    } else {
        Color.clear
    }
}

private func oneLine(_ s: String) -> String {
    let line = s.split(whereSeparator: \.isNewline).map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? s
    return String(line.prefix(80))
}

private func markdown(_ src: String) -> AttributedString {
    (try? AttributedString(markdown: src, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(src)
}
