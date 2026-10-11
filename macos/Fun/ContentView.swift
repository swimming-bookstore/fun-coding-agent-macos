import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
        .task {
            viewModel.start()
            #if FUN_DEMO
            DemoDriver.maybeStart(viewModel: viewModel)
            #endif
        }
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

private struct ModelField: View {
    @ObservedObject var viewModel: FunViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("model", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .frame(width: 128)
            .focused($focused)
            .disabled(viewModel.snapshot.empty)
            .help("Model for the next message. Return to apply. Restarts this chat's worker; the transcript stays.")
            .onSubmit { apply() }
            .onAppear { text = saved() }
            .onChange(of: focused) { _, on in
                if !on { text = saved() }
            }
    }

    private func saved() -> String {
        UserDefaults.standard.string(forKey: "fun.model") ?? "grok-4.7"
    }

    private func apply() {
        let model = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            text = saved()
            return
        }
        text = model
        UserDefaults.standard.set(model, forKey: "fun.model")
        viewModel.setModel(model)
        focused = false
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
                        Button("Remove Folder", role: .destructive) {
                            viewModel.removeFolder(room.workspace)
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: deleteSelected)
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

    private func deleteSelected() {
        guard let path = selection.wrappedValue else { return }
        viewModel.removeFolder(path)
    }
}

private struct RoomRowView: View {
    let room: RoomInfo

    var body: some View {
        HStack(spacing: 10) {
            statusMark(working: room.working, error: room.error, done: room.done)
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
    @State private var pinnedToBottom = true
    private let threadEnd = "thread-end"

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.snapshot.items, id: \.id) { item in
                            ChatItemView(item: item, onImageLaidOut: { followBottom(proxy) })
                        }
                        Color.clear.frame(height: 1).id(threadEnd)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BottomPinTracker(pinned: $pinnedToBottom))
                }
                .modifier(BottomScrollAnchor())
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasDocks { docks }
                }
                .onAppear { jumpToEnd(proxy) }
                .onChange(of: viewModel.snapshot.items.last?.id) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.items.last?.body) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.items.last?.streaming) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.items.count) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.thinking) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.steer) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.queue.count) { _, _ in followBottom(proxy) }
                .onChange(of: viewModel.snapshot.rooms.first { $0.selected }?.workspace) { _, _ in
                    jumpToEnd(proxy)
                }
            }
            Composer(viewModel: viewModel)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func followBottom(_ proxy: ScrollViewProxy) {
        guard pinnedToBottom else { return }
        scrollToEnd(proxy)
    }

    private func jumpToEnd(_ proxy: ScrollViewProxy) {
        pinnedToBottom = true
        scrollToEnd(proxy)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        // After the current layout pass. scrollTo during update blanks the
        // thread or lands on a stale height (looks like a jump to the top).
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(threadEnd, anchor: .bottom)
            }
        }
    }

    private var hasDocks: Bool {
        !viewModel.snapshot.thinking.isEmpty
            || !viewModel.snapshot.steer.isEmpty
            || (!viewModel.snapshot.loggedIn && !viewModel.snapshot.empty)
            || !viewModel.snapshot.queue.isEmpty
    }

    @ViewBuilder
    private var docks: some View {
        VStack(spacing: 0) {
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
            if !viewModel.snapshot.loggedIn && !viewModel.snapshot.empty {
                Dock(title: "Grok") {
                    HStack {
                        Text("Log in to Grok to keep chatting.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Log In to Grok") { viewModel.loginGrok() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(viewModel.snapshot.login != nil)
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
        }
    }

}

private struct BottomPinTracker: NSViewRepresentable {
    @Binding var pinned: Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.pinned = $pinned
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.pinned = $pinned
        context.coordinator.attach(from: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var pinned: Binding<Bool> = .constant(true)
        private weak var scrollView: NSScrollView?
        private var liveObservers: [NSObjectProtocol] = []
        private var momentumPin: DispatchWorkItem?

        deinit {
            liveObservers.forEach { NotificationCenter.default.removeObserver($0) }
            momentumPin?.cancel()
        }

        func attach(from view: NSView) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = view.enclosingScrollView else { return }
                if self.scrollView === scroll { return }
                liveObservers.forEach { NotificationCenter.default.removeObserver($0) }
                liveObservers.removeAll()
                self.scrollView = scroll
                func observe(_ name: Notification.Name, _ body: @escaping (Coordinator) -> Void) {
                    self.liveObservers.append(NotificationCenter.default.addObserver(
                        forName: name,
                        object: scroll,
                        queue: .main
                    ) { [weak self] _ in
                        guard let self else { return }
                        body(self)
                    })
                }
                observe(NSScrollView.willStartLiveScrollNotification) {
                    $0.momentumPin?.cancel()
                }
                observe(NSScrollView.didLiveScrollNotification) {
                    $0.updatePinFromUserScroll()
                }
                observe(NSScrollView.didEndLiveScrollNotification) {
                    $0.updatePinFromUserScroll()
                    $0.scheduleMomentumPin()
                }
            }
        }

        private func updatePinFromUserScroll() {
            let value = distanceFromBottom() <= 72
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pinned.wrappedValue != value else { return }
                self.pinned.wrappedValue = value
            }
        }

        private func scheduleMomentumPin() {
            momentumPin?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.updatePinFromUserScroll()
            }
            momentumPin = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        private func distanceFromBottom() -> CGFloat {
            guard let scroll = scrollView else { return 0 }
            let visible = scroll.contentView.bounds
            let docHeight = scroll.documentView?.frame.height ?? 0
            if scroll.documentView?.isFlipped == true {
                return docHeight - (visible.origin.y + visible.height)
            }
            return visible.origin.y
        }
    }
}

private struct BottomScrollAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
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
            Text("\(item.index + 1).")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
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
            && (!viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !viewModel.images.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !viewModel.images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(viewModel.images.enumerated()), id: \.offset) { index, image in
                                ImageChip(name: image.name) {
                                    viewModel.dropImage(index)
                                }
                            }
                        }
                    }
                }
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
                    ModelField(viewModel: viewModel)
                    Button {
                        viewModel.attachImages()
                    } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle)
                    .controlSize(.regular)
                    .help("Attach a png, jpeg, gif, or webp (4 MB max). Drop a file here too.")
                    .disabled(viewModel.snapshot.empty)
                    Button("Send") { viewModel.submit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!canSend)
                        .help("Return to send  ·  Control-Return interrupt  ·  Option-Return newline")
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            viewModel.takeDrop(providers)
        }
    }
}

private struct ImageChip: View {
    let name: String
    let onDrop: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.caption)
            Text(name.isEmpty ? "image" : name)
                .lineLimit(1)
            Button(action: onDrop) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .help("Remove image")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct ChatItemView: View {
    let item: ChatItem
    var onImageLaidOut: () -> Void = {}

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 2) {
                Text("You")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "[image]" : item.body)
                    .foregroundStyle(.primary)
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
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .note:
            if item.toolDetail.isEmpty {
                Text(item.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                DisclosureGroup(item.body) {
                    Text(item.toolDetail)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool:
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup(item.toolSummary) {
                    Text(item.toolDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                }
                if !item.images.isEmpty {
                    ForEach(Array(item.images.enumerated()), id: \.offset) { _, image in
                        ChatImageView(image: image, onLaidOut: onImageLaidOut)
                            .id(image.path)
                    }
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ChatImageView: View {
    let image: ChatImage
    var onLaidOut: () -> Void = {}
    @State private var loaded: NSImage?
    @State private var showingPreview = false
    @State private var inView = false
    @State private var wellHeight: CGFloat = 200
    @State private var didAnnounceLayout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let loaded {
                    Button {
                        showingPreview = true
                    } label: {
                        Image(nsImage: loaded)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help("Open image")
                    .sheet(isPresented: $showingPreview) {
                        ImagePreview(path: image.path, name: image.name)
                    }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                }
            }
            .frame(maxWidth: 420, minHeight: wellHeight, maxHeight: wellHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            if !image.name.isEmpty {
                Text(image.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .background(VisibilityProbe { visible in
            inView = visible
        })
        .task(id: "\(inView ? "1" : "0")|\(image.path)") {
            let path = image.path
            guard inView else {
                loaded = nil
                return
            }
            if let cached = ChatImageStore.thumbnail(path) {
                apply(cached)
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                ChatImageStore.decodeThumbnail(path: path)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded {
                ChatImageStore.setThumbnail(path, decoded)
                apply(decoded)
            }
        }
    }

    private func apply(_ image: NSImage) {
        loaded = image
        let size = image.size
        if size.width > 0, size.height > 0 {
            let height = min(320, max(160, 420 * size.height / size.width))
            if abs(wellHeight - height) > 1 {
                wellHeight = height
            }
        }
        announceLayout()
    }

    private func announceLayout() {
        guard !didAnnounceLayout else { return }
        didAnnounceLayout = true
        onLaidOut()
    }
}

private enum ChatImageStore {
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 6
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    private static let full: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private static let thumbPixel: CGFloat = 840

    static func thumbnail(_ path: String) -> NSImage? {
        thumbnails.object(forKey: path as NSString)
    }

    static func setThumbnail(_ path: String, _ image: NSImage) {
        thumbnails.setObject(image, forKey: path as NSString, cost: cost(image))
    }

    static func fullImage(_ path: String) -> NSImage? {
        full.object(forKey: path as NSString)
    }

    static func setFull(_ path: String, _ image: NSImage) {
        full.setObject(image, forKey: path as NSString, cost: cost(image))
    }

    static func decodeThumbnail(path: String) -> NSImage? {
        decode(path: path, maxPixel: thumbPixel)
    }

    static func decodeFull(path: String) -> NSImage? {
        decode(path: path, maxPixel: 4096)
    }

    private static func decode(path: String, maxPixel: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func cost(_ image: NSImage) -> Int {
        let size = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 }
            ?? Int(image.size.width * image.size.height * 4)
        return max(size, 1)
    }
}

private struct VisibilityProbe: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = onChange
        nsView.scheduleCheck()
    }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var lastVisible: Bool?
        private var observers: [NSObjectProtocol] = []
        private weak var clip: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            scheduleCheck()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
            scheduleCheck()
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func scheduleCheck() {
            DispatchQueue.main.async { [weak self] in
                self?.check()
            }
        }

        private func attach() {
            guard let scroll = enclosingScrollView else { return }
            let next = scroll.contentView
            if clip === next { return }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            clip = next
            next.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: next,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleCheck()
            })
        }

        private func check() {
            guard window != nil, let scroll = enclosingScrollView else {
                emit(false)
                return
            }
            let pad: CGFloat = lastVisible == true ? 360 : 80
            let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -pad)
            let frameInClip = convert(bounds, to: scroll.contentView)
            emit(visible.intersects(frameInClip))
        }

        private func emit(_ visible: Bool) {
            guard lastVisible != visible else { return }
            lastVisible = visible
            onChange?(visible)
        }
    }
}

private struct ImagePreview: View {
    let path: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(28)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                if !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 540)
        .task(id: path) {
            if let cached = ChatImageStore.fullImage(path) {
                image = cached
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                ChatImageStore.decodeFull(path: path)
            }.value
            if let decoded {
                ChatImageStore.setFull(path, decoded)
            }
            guard !Task.isCancelled else { return }
            image = decoded
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
    ZStack {
        if working {
            ProgressView()
                .controlSize(.mini)
        } else if done {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        } else if error {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.red)
        } else {
            Image(systemName: "bubble.left")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }
    .frame(width: 16, height: 16)
}

private func oneLine(_ s: String) -> String {
    let line = s.split(whereSeparator: \.isNewline).map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? s
    return String(line.prefix(80))
}

private func markdown(_ src: String) -> AttributedString {
    (try? AttributedString(markdown: src, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(src)
}
