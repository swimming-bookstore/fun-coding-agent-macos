//! Rust core for the Fun macOS app.
//!
//! Agent, tools, sessions, and Grok login live here. Swift only renders the window.

uniffi::setup_scaffolding!();

use fun_core::agent::{
    Agent, LogLine, MailboxTx, ToolRun, args_repr, mailbox, prompt, title_case, tool_counts,
    tool_summary,
};
use fun_core::grok::Grok;
use fun_core::session::{Entry, Session};
use fun_core::tool::get_tools;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

const THINK_HOLD: Duration = Duration::from_secs(2);
const THINK_LINES: usize = 6;
const QUEUE_FLASH: Duration = Duration::from_millis(1200);
const CONTEXT_MAX: u64 = 500_000;

#[derive(Clone, Debug, uniffi::Enum)]
pub enum ChatKind {
    User,
    Agent,
    Note,
    Tool,
    Marker,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ChatItem {
    pub id: u64,
    pub kind: ChatKind,
    pub body: String,
    pub streaming: bool,
    pub tool_summary: String,
    pub tool_detail: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct RoomInfo {
    pub workspace: String,
    pub title: String,
    pub preview: String,
    pub unread: u32,
    pub working: bool,
    pub error: bool,
    pub done: bool,
    pub selected: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct QueueItem {
    pub index: u32,
    pub text: String,
    pub flash: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LoginInfo {
    pub status: String,
    pub user_code: String,
    pub uri: String,
    pub open_url: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct Snapshot {
    pub title: String,
    pub usage: String,
    pub usage_tip: String,
    pub working: bool,
    pub logged_in: bool,
    pub empty: bool,
    pub empty_note: String,
    pub thinking: String,
    pub steer: String,
    pub steer_count: String,
    pub rooms: Vec<RoomInfo>,
    pub items: Vec<ChatItem>,
    pub queue: Vec<QueueItem>,
    pub login: Option<LoginInfo>,
    pub toast: String,
}

/// Implemented in Swift. Hop to the main thread before touching UI.
#[uniffi::export(with_foreign)]
pub trait FunDelegate: Send + Sync {
    fn on_snapshot(&self, snapshot: Snapshot);
}

enum GuiCmd {
    Prompt { text: String, seq: u64 },
    Shutdown,
}

enum Msg {
    Start(Arc<dyn FunDelegate>),
    Submit(String),
    Interrupt(String),
    Abort,
    OpenRoom(String),
    AddFolder(String),
    RemoveFolder,
    NewChat,
    QueueSendNow(u32),
    QueueEdit { index: u32, reply: Sender<String> },
    QueueMove { index: u32, delta: i32 },
    QueueDrop(u32),
    LoginGrok,
    LogoutGrok,
    Toast(String),
    DismissLogin,
    DismissToast,
    Shutdown,
    Login(LoginEv),
}

enum LoginEv {
    Started {
        user_code: String,
        uri: String,
        open: String,
    },
    Done,
    Denied,
    Expired,
    Fail(String),
}

enum Kind {
    User(String),
    Agent(String),
    Note(String),
    Tool(Vec<ToolRun>),
}

struct ChatRun {
    mailbox: MailboxTx,
    cmd: Sender<GuiCmd>,
    log_rx: Receiver<LogLine>,
    done_rx: Receiver<u64>,
    seq: u64,
    working: bool,
    error: bool,
    done: bool,
    draft: String,
    thinking: String,
    think_hide_at: Option<Instant>,
    queued: Vec<String>,
    steered: Vec<String>,
    last_input: u64,
}

struct Room {
    workspace: PathBuf,
    title: String,
    preview: String,
}

struct ToolBlock {
    item_id: u64,
    runs: Vec<ToolRun>,
}

#[derive(Clone)]
struct DiskSeen {
    file: PathBuf,
    len: u64,
    n: usize,
}

struct Inner {
    workspace: PathBuf,
    current: PathBuf,
    provider: Option<Grok>,
    model: String,
    rooms: Vec<Room>,
    runs: HashMap<PathBuf, ChatRun>,
    opened: Vec<PathBuf>,
    unread: HashMap<PathBuf, u32>,
    seen: HashMap<PathBuf, DiskSeen>,
    items: Vec<ChatItem>,
    next_id: u64,
    stream_id: Option<u64>,
    last_tool: Option<ToolBlock>,
    queue_flash: Option<(usize, Instant)>,
    login: Option<LoginInfo>,
    toast: String,
    tick: u32,
    dirty: bool,
}

#[derive(uniffi::Object)]
pub struct FunApp {
    tx: Sender<Msg>,
}

#[uniffi::export]
impl FunApp {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn({
            let tx = tx.clone();
            move || run(tx, rx)
        });
        Arc::new(Self { tx })
    }

    pub fn start(&self, delegate: Arc<dyn FunDelegate>) {
        let _ = self.tx.send(Msg::Start(delegate));
    }

    pub fn submit(&self, text: String) {
        let _ = self.tx.send(Msg::Submit(text));
    }

    pub fn interrupt(&self, text: String) {
        let _ = self.tx.send(Msg::Interrupt(text));
    }

    pub fn abort(&self) {
        let _ = self.tx.send(Msg::Abort);
    }

    pub fn open_room(&self, workspace: String) {
        let _ = self.tx.send(Msg::OpenRoom(workspace));
    }

    pub fn add_folder(&self, workspace: String) {
        let _ = self.tx.send(Msg::AddFolder(workspace));
    }

    pub fn remove_folder(&self) {
        let _ = self.tx.send(Msg::RemoveFolder);
    }

    pub fn new_chat(&self) {
        let _ = self.tx.send(Msg::NewChat);
    }

    pub fn queue_send_now(&self, index: u32) {
        let _ = self.tx.send(Msg::QueueSendNow(index));
    }

    pub fn queue_edit(&self, index: u32) -> String {
        let (reply, rx) = mpsc::channel();
        if self.tx.send(Msg::QueueEdit { index, reply }).is_err() {
            return String::new();
        }
        rx.recv().unwrap_or_default()
    }

    pub fn queue_move(&self, index: u32, delta: i32) {
        let _ = self.tx.send(Msg::QueueMove { index, delta });
    }

    pub fn queue_drop(&self, index: u32) {
        let _ = self.tx.send(Msg::QueueDrop(index));
    }

    pub fn login_grok(&self) {
        let _ = self.tx.send(Msg::LoginGrok);
    }

    pub fn logout_grok(&self) {
        let _ = self.tx.send(Msg::LogoutGrok);
    }

    pub fn dismiss_login(&self) {
        let _ = self.tx.send(Msg::DismissLogin);
    }

    pub fn dismiss_toast(&self) {
        let _ = self.tx.send(Msg::DismissToast);
    }

    pub fn shutdown(&self) {
        let _ = self.tx.send(Msg::Shutdown);
    }
}

struct Core {
    inner: Inner,
    delegate: Option<Arc<dyn FunDelegate>>,
    tx: Sender<Msg>,
}

fn run(tx: Sender<Msg>, rx: Receiver<Msg>) {
    let cfg = fun_core::config::load();
    if let Some(path) = cfg.auth {
        provider_grok::set_auth_path(path);
    }
    let (provider, model) = match grok_client() {
        Some(ok) => (Some(ok.0), ok.1),
        None => (None, String::new()),
    };
    let opened = load_opened();
    let workspace = opened.first().cloned().unwrap_or_default();
    let session = if workspace.as_os_str().is_empty() {
        None
    } else {
        latest_or_create(&workspace)
    };
    let current = session.as_ref().map(|s| s.path.clone()).unwrap_or_default();
    let rooms = rooms_for(&opened);
    let mut inner = Inner {
        workspace: workspace.clone(),
        current,
        provider,
        model,
        rooms,
        runs: HashMap::new(),
        opened,
        unread: HashMap::new(),
        seen: HashMap::new(),
        items: Vec::new(),
        next_id: 1,
        stream_id: None,
        last_tool: None,
        queue_flash: None,
        login: None,
        toast: String::new(),
        tick: 0,
        dirty: true,
    };
    if let Some(session) = session {
        ensure_run(&mut inner, workspace.clone(), session.path.clone());
        show_history(&mut inner, &session, 0);
    } else {
        append_item(
            &mut inner,
            Kind::Note("Open a folder to start a chat.".into()),
            false,
        );
    }
    let mut core = Core {
        inner,
        delegate: None,
        tx,
    };
    loop {
        match rx.recv_timeout(Duration::from_millis(50)) {
            Ok(msg) => {
                let halt = matches!(msg, Msg::Shutdown);
                handle(&mut core, msg);
                if halt {
                    shutdown_runs(&mut core.inner);
                    return;
                }
            }
            Err(RecvTimeoutError::Timeout) => {
                drain(&mut core.inner);
                emit_if_dirty(&mut core);
            }
            Err(RecvTimeoutError::Disconnected) => {
                shutdown_runs(&mut core.inner);
                return;
            }
        }
    }
}

fn handle(core: &mut Core, msg: Msg) {
    match msg {
        Msg::Start(delegate) => {
            core.delegate = Some(delegate);
        }
        Msg::Submit(text) => submit(&mut core.inner, text),
        Msg::Interrupt(text) => interrupt_now(&mut core.inner, text),
        Msg::Abort => abort_current(&mut core.inner),
        Msg::OpenRoom(workspace) => open_room(&mut core.inner, Path::new(&workspace)),
        Msg::AddFolder(workspace) => add_folder(&mut core.inner, PathBuf::from(workspace)),
        Msg::RemoveFolder => {
            let ws = core.inner.workspace.clone();
            remove_folder(&mut core.inner, &ws);
        }
        Msg::NewChat => new_chat(&mut core.inner),
        Msg::QueueSendNow(index) => queue_send_now(&mut core.inner, index as usize),
        Msg::QueueEdit { index, reply } => {
            let text = queue_edit(&mut core.inner, index as usize);
            let _ = reply.send(text);
        }
        Msg::QueueMove { index, delta } => queue_move(&mut core.inner, index as usize, delta),
        Msg::QueueDrop(index) => queue_drop(&mut core.inner, index as usize),
        Msg::LoginGrok => {
            core.inner.login = Some(LoginInfo {
                status: "Starting…".into(),
                user_code: String::new(),
                uri: String::new(),
                open_url: String::new(),
            });
            core.inner.toast.clear();
            login_thread(core.tx.clone());
        }
        Msg::LogoutGrok => {
            core.inner.login = None;
            logout_thread(core.tx.clone());
        }
        Msg::Toast(msg) => core.inner.toast = msg,
        Msg::DismissLogin => core.inner.login = None,
        Msg::DismissToast => core.inner.toast.clear(),
        Msg::Shutdown => {}
        Msg::Login(ev) => apply_login(&mut core.inner, ev),
    }
    core.inner.dirty = true;
    emit_if_dirty(core);
}

fn emit_if_dirty(core: &mut Core) {
    if !core.inner.dirty {
        return;
    }
    core.inner.dirty = false;
    let Some(d) = core.delegate.clone() else {
        return;
    };
    d.on_snapshot(snapshot(&core.inner));
}

fn shutdown_runs(inner: &mut Inner) {
    for run in inner.runs.values() {
        let _ = run.cmd.send(GuiCmd::Shutdown);
        run.mailbox.abort();
    }
}

fn block_on<T>(fut: impl std::future::Future<Output = T>) -> Option<T> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .ok()
        .map(|rt| rt.block_on(fut))
}

fn grok_client() -> Option<(Grok, String)> {
    block_on(Grok::client())?.ok()
}

fn logout_thread(tx: Sender<Msg>) {
    std::thread::spawn(move || {
        let msg = match block_on(provider_grok::logout()) {
            Some(Ok(true)) => "Logged out of Grok.",
            Some(Ok(false)) => "Not logged in.",
            _ => "Could not log out.",
        };
        let _ = tx.send(Msg::Toast(msg.into()));
    });
}

fn apply_login(inner: &mut Inner, ev: LoginEv) {
    match ev {
        LoginEv::Started {
            user_code,
            uri,
            open,
        } => {
            inner.login = Some(LoginInfo {
                status: "Visit xAI and enter this code:".into(),
                user_code,
                uri,
                open_url: open,
            });
        }
        LoginEv::Done => {
            inner.login = None;
            inner.toast = "Logged in.".into();
        }
        LoginEv::Denied => {
            if let Some(l) = inner.login.as_mut() {
                l.status = "Login was denied.".into();
            }
        }
        LoginEv::Expired => {
            if let Some(l) = inner.login.as_mut() {
                l.status = "Login code expired. Try again.".into();
            }
        }
        LoginEv::Fail(e) => {
            if let Some(l) = inner.login.as_mut() {
                l.status = e;
            }
        }
    }
}

fn login_thread(tx: Sender<Msg>) {
    std::thread::spawn(move || {
        let Some(rt) = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .ok()
        else {
            let _ = tx.send(Msg::Login(LoginEv::Fail("could not start login".into())));
            return;
        };
        let start = match rt.block_on(provider_grok::start_login()) {
            Ok(s) => s,
            Err(e) => {
                let _ = tx.send(Msg::Login(LoginEv::Fail(format!("{e:#}"))));
                return;
            }
        };
        let device_code = start.device_code.clone();
        let mut interval = start.interval.max(1);
        let deadline_ms = start.deadline_ms;
        let _ = tx.send(Msg::Login(LoginEv::Started {
            user_code: start.user_code,
            uri: start.verification_uri,
            open: start.verification_uri_complete,
        }));
        loop {
            std::thread::sleep(Duration::from_secs(interval));
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            if now >= deadline_ms {
                let _ = tx.send(Msg::Login(LoginEv::Expired));
                return;
            }
            match rt.block_on(provider_grok::poll_token(&device_code)) {
                Ok(provider_grok::Poll::Done) => {
                    let _ = tx.send(Msg::Login(LoginEv::Done));
                    return;
                }
                Ok(provider_grok::Poll::Pending) => {}
                Ok(provider_grok::Poll::SlowDown(n)) => interval = n.max(1),
                Ok(provider_grok::Poll::Denied) => {
                    let _ = tx.send(Msg::Login(LoginEv::Denied));
                    return;
                }
                Ok(provider_grok::Poll::Expired) => {
                    let _ = tx.send(Msg::Login(LoginEv::Expired));
                    return;
                }
                Err(e) => {
                    let _ = tx.send(Msg::Login(LoginEv::Fail(format!("{e:#}"))));
                    return;
                }
            }
        }
    });
}

fn snapshot(inner: &Inner) -> Snapshot {
    let empty = inner.workspace.as_os_str().is_empty();
    let ws = &inner.workspace;
    let working = is_working(inner, ws);
    let tokens = run_get(&inner.runs, ws).map(|r| r.last_input).unwrap_or(0);
    let thinking = run_get(&inner.runs, ws)
        .map(|r| think_preview(&r.thinking))
        .unwrap_or_default();
    let steered = run_get(&inner.runs, ws)
        .map(|r| r.steered.clone())
        .unwrap_or_default();
    let (steer, steer_count) = if steered.is_empty() {
        (String::new(), String::new())
    } else if steered.len() > 1 {
        (one_line(&steered[0]), format!("×{}", steered.len()))
    } else {
        (one_line(&steered[0]), String::new())
    };
    Snapshot {
        title: if empty { "Fun".into() } else { folder_name(ws) },
        usage: usage_text(tokens),
        usage_tip: usage_tip(tokens),
        working,
        logged_in: provider_grok::has_tokens(),
        empty,
        empty_note: if empty {
            "Open a folder to start a chat.".into()
        } else {
            String::new()
        },
        thinking,
        steer,
        steer_count,
        rooms: inner
            .rooms
            .iter()
            .map(|r| RoomInfo {
                workspace: r.workspace.display().to_string(),
                title: r.title.clone(),
                preview: r.preview.clone(),
                unread: unread_for(inner, &r.workspace),
                working: is_working(inner, &r.workspace),
                error: is_error(inner, &r.workspace),
                done: is_done(inner, &r.workspace),
                selected: same_dir(&r.workspace, ws),
            })
            .collect(),
        items: inner.items.clone(),
        queue: queue_items(inner),
        login: inner.login.clone(),
        toast: inner.toast.clone(),
    }
}

fn queue_items(inner: &Inner) -> Vec<QueueItem> {
    let current = &inner.workspace;
    let items = run_get(&inner.runs, current)
        .map(|r| r.queued.clone())
        .unwrap_or_default();
    let now = Instant::now();
    let flash = match inner.queue_flash {
        Some((i, until)) if now < until && i < items.len() => Some(i),
        _ => None,
    };
    items
        .into_iter()
        .enumerate()
        .map(|(i, text)| QueueItem {
            index: i as u32,
            text,
            flash: flash == Some(i),
        })
        .collect()
}

fn rooms_for(opened: &[PathBuf]) -> Vec<Room> {
    opened.iter().map(|ws| room_from(ws)).collect()
}

fn room_from(workspace: &Path) -> Room {
    let preview = match Session::open_latest(workspace) {
        Ok(Some(s)) => {
            let p = session_preview(&s);
            if p.is_empty() {
                "No messages yet".into()
            } else {
                p
            }
        }
        _ => "No messages yet".into(),
    };
    Room {
        workspace: workspace.to_path_buf(),
        title: folder_name(workspace),
        preview,
    }
}

fn latest_or_create(workspace: &Path) -> Option<Session> {
    match Session::open_latest(workspace) {
        Ok(Some(s)) => Some(s),
        Ok(None) => Session::create(workspace).ok(),
        Err(_) => Session::create(workspace).ok(),
    }
}

fn open_room(inner: &mut Inner, workspace: &Path) {
    if workspace.as_os_str().is_empty() {
        return;
    }
    let already = same_dir(workspace, &inner.workspace);
    let unread = take_unread(inner, workspace);
    let Some(session) = latest_or_create(workspace) else {
        return;
    };
    inner.workspace = workspace.to_path_buf();
    inner.current = session.path.clone();
    ensure_run(inner, workspace.to_path_buf(), session.path.clone());
    if !already {
        show_history(inner, &session, unread);
        resume_stream(inner, workspace);
        inner.queue_flash = None;
    }
}

fn add_folder(inner: &mut Inner, workspace: PathBuf) {
    let workspace = match workspace.canonicalize() {
        Ok(p) => p,
        Err(_) => workspace,
    };
    remember_opened(inner, &workspace);
    refresh_rooms(inner);
    open_room(inner, &workspace);
}

fn remove_folder(inner: &mut Inner, workspace: &Path) {
    stop_run(inner, workspace);
    forget_opened(inner, workspace);
    refresh_rooms(inner);
    if same_dir(&inner.workspace, workspace) {
        if let Some(next) = inner.rooms.first().map(|r| r.workspace.clone()) {
            open_room(inner, &next);
        } else {
            inner.workspace = PathBuf::new();
            inner.current = PathBuf::new();
            clear_thread(inner);
            append_item(
                inner,
                Kind::Note("Open a folder to start a chat.".into()),
                false,
            );
        }
    }
}

fn refresh_rooms(inner: &mut Inner) {
    inner.rooms = rooms_for(&inner.opened);
}

fn new_chat(inner: &mut Inner) {
    let workspace = inner.workspace.clone();
    if workspace.as_os_str().is_empty() {
        return;
    }
    stop_run(inner, &workspace);
    let Ok(session) = Session::create(&workspace) else {
        return;
    };
    inner.current = session.path.clone();
    take_unread(inner, &workspace);
    ensure_run(inner, workspace.clone(), session.path.clone());
    show_history(inner, &session, 0);
    update_preview(inner, &workspace, "No messages yet");
    inner.queue_flash = None;
}

fn resume_stream(inner: &mut Inner, workspace: &Path) {
    let draft = run_get(&inner.runs, workspace)
        .map(|r| r.draft.clone())
        .unwrap_or_default();
    inner.stream_id = None;
    if draft.trim().is_empty() {
        return;
    }
    if let Some(id) = append_item(inner, Kind::Agent(draft), true) {
        inner.stream_id = Some(id);
    }
}

fn show_history(inner: &mut Inner, session: &Session, unread: u32) {
    clear_thread(inner);
    let history = replay(session);
    if history.is_empty() {
        return;
    }
    let split = unread_split(&history, unread);
    for (i, kind) in history.into_iter().enumerate() {
        if i == split {
            append_marker(inner);
        }
        append_item(inner, kind, false);
    }
}

fn unread_split(history: &[Kind], unread: u32) -> usize {
    if unread == 0 {
        return history.len();
    }
    let mut left = unread;
    for i in (0..history.len()).rev() {
        if matches!(history[i], Kind::Agent(_)) {
            left = left.saturating_sub(1);
            if left == 0 {
                return i;
            }
        }
    }
    0
}

fn clear_thread(inner: &mut Inner) {
    inner.stream_id = None;
    inner.last_tool = None;
    inner.items.clear();
}

fn append_marker(inner: &mut Inner) {
    let id = inner.next_id;
    inner.next_id += 1;
    inner.items.push(ChatItem {
        id,
        kind: ChatKind::Marker,
        body: "New messages".into(),
        streaming: false,
        tool_summary: String::new(),
        tool_detail: String::new(),
    });
}

fn append_item(inner: &mut Inner, kind: Kind, streaming: bool) -> Option<u64> {
    let empty = match &kind {
        Kind::User(s) | Kind::Agent(s) | Kind::Note(s) => s.trim().is_empty(),
        Kind::Tool(runs) => runs.is_empty(),
    };
    if empty {
        return None;
    }
    let is_tool = matches!(kind, Kind::Tool { .. });
    let id = inner.next_id;
    inner.next_id += 1;
    let item = match kind {
        Kind::User(body) => ChatItem {
            id,
            kind: ChatKind::User,
            body,
            streaming: false,
            tool_summary: String::new(),
            tool_detail: String::new(),
        },
        Kind::Agent(body) => ChatItem {
            id,
            kind: ChatKind::Agent,
            body,
            streaming,
            tool_summary: String::new(),
            tool_detail: String::new(),
        },
        Kind::Note(body) => ChatItem {
            id,
            kind: ChatKind::Note,
            body,
            streaming: false,
            tool_summary: String::new(),
            tool_detail: String::new(),
        },
        Kind::Tool(runs) => {
            let (ok, fail) = tool_counts(&runs);
            let detail = tool_detail(&runs);
            inner.last_tool = Some(ToolBlock {
                item_id: id,
                runs: runs.clone(),
            });
            ChatItem {
                id,
                kind: ChatKind::Tool,
                body: String::new(),
                streaming: false,
                tool_summary: tool_summary(ok, fail),
                tool_detail: detail,
            }
        }
    };
    let stream_id = match item.kind {
        ChatKind::Agent if streaming => Some(id),
        _ => None,
    };
    if !is_tool {
        inner.last_tool = None;
    }
    inner.items.push(item);
    stream_id
}

fn submit(inner: &mut Inner, raw: String) {
    let text = raw.trim().to_string();
    if text.is_empty() || inner.workspace.as_os_str().is_empty() {
        return;
    }
    let workspace = inner.workspace.clone();
    let path = inner.current.clone();
    ensure_run(inner, workspace.clone(), path);
    let working = {
        let Some(run) = run_mut(&mut inner.runs, &workspace) else {
            return;
        };
        if run.working {
            run.mailbox.idle(text.clone());
            run.queued.push(text.clone());
            true
        } else {
            run.working = true;
            run.error = false;
            run.done = false;
            run.seq = run.seq.wrapping_add(1);
            let seq = run.seq;
            let _ = run.cmd.send(GuiCmd::Prompt {
                text: text.clone(),
                seq,
            });
            false
        }
    };
    if working {
        return;
    }
    show_user(inner, text);
}

fn interrupt_now(inner: &mut Inner, raw: String) {
    let text = raw.trim().to_string();
    if text.is_empty() {
        return;
    }
    let workspace = inner.workspace.clone();
    if !is_working(inner, &workspace) {
        submit(inner, text);
        return;
    }
    if let Some(run) = run_get(&inner.runs, &workspace) {
        run.mailbox.interrupt(text.clone());
    }
    show_user(inner, text);
}

fn abort_current(inner: &mut Inner) {
    let workspace = inner.workspace.clone();
    if let Some(run) = run_get(&inner.runs, &workspace) {
        run.mailbox.abort();
    }
    if let Some(run) = run_mut(&mut inner.runs, &workspace) {
        run.working = false;
        run.queued.clear();
        run.steered.clear();
        clear_think(run);
        run.seq = run.seq.wrapping_add(1);
    }
}

fn show_user(inner: &mut Inner, text: String) {
    append_item(inner, Kind::User(text.clone()), false);
    let ws = inner.workspace.clone();
    update_preview(inner, &ws, &format_preview("You", &text));
}

fn queue_send_now(inner: &mut Inner, i: usize) {
    let workspace = inner.workspace.clone();
    if let Some(run) = run_mut(&mut inner.runs, &workspace) {
        if i < run.queued.len() {
            let text = run.queued.remove(i);
            run.mailbox.set_idle(run.queued.clone());
            run.mailbox.steer(text.clone());
            run.steered.push(text);
        }
    }
}

fn queue_edit(inner: &mut Inner, i: usize) -> String {
    let workspace = inner.workspace.clone();
    let mut pulled = String::new();
    if let Some(run) = run_mut(&mut inner.runs, &workspace) {
        if i < run.queued.len() {
            pulled = run.queued.remove(i);
            run.mailbox.set_idle(run.queued.clone());
        }
    }
    pulled
}

fn queue_move(inner: &mut Inner, i: usize, delta: i32) {
    let workspace = inner.workspace.clone();
    let mut dest = None;
    if let Some(run) = run_mut(&mut inner.runs, &workspace) {
        let j = i as i32 + delta;
        if i < run.queued.len() && j >= 0 && (j as usize) < run.queued.len() {
            run.queued.swap(i, j as usize);
            run.mailbox.set_idle(run.queued.clone());
            dest = Some(j as usize);
        }
    }
    if let Some(j) = dest {
        inner.queue_flash = Some((j, Instant::now() + QUEUE_FLASH));
    }
}

fn queue_drop(inner: &mut Inner, i: usize) {
    let workspace = inner.workspace.clone();
    if let Some(run) = run_mut(&mut inner.runs, &workspace) {
        if i < run.queued.len() {
            run.queued.remove(i);
            run.mailbox.set_idle(run.queued.clone());
        }
    }
}

fn update_preview(inner: &mut Inner, workspace: &Path, preview: &str) {
    if let Some(room) = inner
        .rooms
        .iter_mut()
        .find(|r| same_dir(&r.workspace, workspace))
    {
        room.preview = preview.to_string();
    }
}

fn is_working(inner: &Inner, workspace: &Path) -> bool {
    inner
        .runs
        .iter()
        .any(|(p, r)| r.working && same_dir(p, workspace))
}

fn is_error(inner: &Inner, workspace: &Path) -> bool {
    inner
        .runs
        .iter()
        .any(|(p, r)| r.error && same_dir(p, workspace))
}

fn is_done(inner: &Inner, workspace: &Path) -> bool {
    inner
        .runs
        .iter()
        .any(|(p, r)| r.done && same_dir(p, workspace))
}

fn dismiss_think(run: &mut ChatRun) {
    if run.thinking.trim().is_empty() {
        run.think_hide_at = None;
        return;
    }
    if run.think_hide_at.is_none() {
        run.think_hide_at = Some(Instant::now() + THINK_HOLD);
    }
}

fn clear_think(run: &mut ChatRun) {
    run.thinking.clear();
    run.think_hide_at = None;
}

fn append_think(buf: &mut String, chunk: &str) {
    if chunk.is_empty() {
        return;
    }
    if buf.ends_with(chunk) {
        return;
    }
    if chunk.starts_with(buf.as_str()) && chunk.len() >= buf.len() {
        buf.clear();
        buf.push_str(chunk);
        return;
    }
    buf.push_str(chunk);
}

fn think_preview(raw: &str) -> String {
    let t = raw.trim();
    if t.is_empty() {
        return String::new();
    }
    let lines = wrap_think(t);
    if lines.is_empty() {
        return String::new();
    }
    let start = lines.len().saturating_sub(THINK_LINES);
    lines[start..].join("\n")
}

fn wrap_think(raw: &str) -> Vec<String> {
    let mut out = Vec::new();
    for para in raw.lines() {
        if para.is_empty() {
            out.push(String::new());
            continue;
        }
        let mut cur = String::new();
        for word in para.split_whitespace() {
            if cur.is_empty() {
                cur = word.to_string();
            } else if cur.len() + 1 + word.len() > 88 {
                out.push(std::mem::take(&mut cur));
                cur = word.to_string();
            } else {
                cur.push(' ');
                cur.push_str(word);
            }
        }
        if !cur.is_empty() {
            out.push(cur);
        }
    }
    out
}

fn drain(inner: &mut Inner) {
    let current = inner.workspace.clone();
    let now = Instant::now();
    let mut current_lines = Vec::new();
    let mut bumped = Vec::new();
    let mut previews = Vec::new();
    let mut got = false;
    for (path, run) in inner.runs.iter_mut() {
        if let Some(at) = run.think_hide_at
            && now >= at
        {
            run.thinking.clear();
            run.think_hide_at = None;
            got = true;
        }
        let mut lines = Vec::new();
        while let Ok(line) = run.log_rx.try_recv() {
            got = true;
            if log_is_error(&line) {
                run.error = true;
            }
            match &line {
                LogLine::Think(t) => {
                    run.think_hide_at = None;
                    append_think(&mut run.thinking, t);
                }
                LogLine::Delta(t) => {
                    run.draft.push_str(t);
                    dismiss_think(run);
                }
                LogLine::End => {
                    if !run.draft.trim().is_empty() {
                        previews.push((path.clone(), format_preview("Fun", &run.draft)));
                        if !same_dir(path, &current) {
                            bumped.push(path.clone());
                        }
                    }
                    run.draft.clear();
                    dismiss_think(run);
                }
                LogLine::Text(t) if !t.trim().is_empty() => {
                    run.draft.clear();
                    dismiss_think(run);
                    previews.push((path.clone(), format_preview("Fun", t)));
                    if !same_dir(path, &current) {
                        bumped.push(path.clone());
                    }
                }
                LogLine::User(t) => {
                    if let Some(i) = run.queued.iter().position(|q| q == t) {
                        run.queued.remove(i);
                    }
                    if let Some(i) = run.steered.iter().position(|s| s == t) {
                        run.steered.remove(i);
                    }
                    clear_think(run);
                }
                LogLine::Tools { .. } => {
                    dismiss_think(run);
                }
                LogLine::Usage(u) => {
                    run.last_input = u.last_input_tokens;
                }
                _ => {}
            }
            lines.push(line);
        }
        while let Ok(seq) = run.done_rx.try_recv() {
            got = true;
            if seq != run.seq {
                continue;
            }
            run.working = false;
            run.done = true;
            dismiss_think(run);
            if let Some(preview) = Session::open_latest(path)
                .ok()
                .flatten()
                .map(|s| session_preview(&s))
                .filter(|s| !s.is_empty())
            {
                previews.push((path.clone(), preview));
            }
        }
        if same_dir(path, &current) {
            current_lines.extend(lines);
        }
    }
    for (path, preview) in previews {
        update_preview(inner, &path, &preview);
    }
    for path in bumped {
        add_unread(inner, &path);
    }
    for line in current_lines {
        apply_log(inner, line);
    }
    let n = inner.tick.wrapping_add(1);
    inner.tick = n;
    if n % 20 == 0 {
        sync_disk(inner);
        got = true;
    }
    if let Some((_, until)) = inner.queue_flash {
        if now >= until {
            inner.queue_flash = None;
            got = true;
        }
    }
    if got {
        inner.dirty = true;
    }
}

fn sync_disk(inner: &mut Inner) {
    let current = inner.workspace.clone();
    let opened = inner.opened.clone();
    let mut reload_open = false;
    let mut preview_updates = Vec::new();
    let mut unread_paths = Vec::new();
    for ws in opened {
        let Some(file) = Session::latest_file(&ws).ok().flatten() else {
            continue;
        };
        let len = match file.metadata() {
            Ok(m) => m.len(),
            Err(_) => 0,
        };
        let Ok(session) = Session::load(file.clone()) else {
            continue;
        };
        let n = session.entries.len();
        let preview = session_preview(&session);
        let last = inner
            .seen
            .iter()
            .find(|(p, _)| same_dir(p, &ws))
            .map(|(_, s)| s.clone());
        let changed = match &last {
            None => {
                remember_seen(inner, &ws, file, len, n);
                false
            }
            Some(old) if old.file == file && old.len == len && old.n == n => false,
            Some(_) => {
                remember_seen(inner, &ws, file, len, n);
                true
            }
        };
        if !changed {
            continue;
        }
        if !preview.is_empty() {
            preview_updates.push((ws.clone(), preview));
        }
        if same_dir(&ws, &current) {
            if !run_owns(&ws, inner) {
                reload_open = true;
            }
        } else if !run_owns(&ws, inner) {
            unread_paths.push(ws);
        }
    }
    for (ws, preview) in preview_updates {
        update_preview(inner, &ws, &preview);
    }
    for ws in unread_paths {
        add_unread(inner, &ws);
    }
    if reload_open {
        if let Ok(Some(session)) = Session::open_latest(&current) {
            inner.current = session.path.clone();
            show_history(inner, &session, 0);
            resume_stream(inner, &current);
        }
    }
}

fn remember_seen(inner: &mut Inner, workspace: &Path, file: PathBuf, len: u64, n: usize) {
    if let Some((_, s)) = inner.seen.iter_mut().find(|(p, _)| same_dir(p, workspace)) {
        *s = DiskSeen { file, len, n };
        return;
    }
    inner
        .seen
        .insert(workspace.to_path_buf(), DiskSeen { file, len, n });
}

fn run_owns(workspace: &Path, inner: &Inner) -> bool {
    inner
        .runs
        .iter()
        .any(|(p, r)| same_dir(p, workspace) && (r.working || !r.draft.is_empty()))
}

fn log_is_error(line: &LogLine) -> bool {
    matches!(line, LogLine::Dim(_))
}

fn add_unread(inner: &mut Inner, workspace: &Path) {
    if same_dir(workspace, &inner.workspace) {
        return;
    }
    if let Some((_, n)) = inner
        .unread
        .iter_mut()
        .find(|(p, _)| same_dir(p, workspace))
    {
        *n += 1;
        return;
    }
    inner.unread.insert(workspace.to_path_buf(), 1);
}

fn take_unread(inner: &mut Inner, workspace: &Path) -> u32 {
    let key = inner
        .unread
        .keys()
        .find(|p| same_dir(p, workspace))
        .cloned();
    match key {
        Some(k) => inner.unread.remove(&k).unwrap_or(0),
        None => 0,
    }
}

fn unread_for(inner: &Inner, workspace: &Path) -> u32 {
    inner
        .unread
        .iter()
        .find(|(p, _)| same_dir(p, workspace))
        .map(|(_, n)| *n)
        .unwrap_or(0)
}

fn ensure_run(inner: &mut Inner, workspace: PathBuf, session_path: PathBuf) {
    if run_get(&inner.runs, &workspace).is_some() {
        return;
    }
    let Ok(session) = Session::load(session_path).or_else(|_| Session::create(&workspace)) else {
        return;
    };
    let last_input = session.usage.last_input_tokens;
    let (tx, mb) = mailbox();
    let (log_tx, log_rx) = mpsc::channel();
    let err_tx = log_tx.clone();
    let (done_tx, done_rx) = mpsc::channel::<u64>();
    let (cmd_tx, cmd_rx) = mpsc::channel::<GuiCmd>();
    let Some(provider) = inner.provider.clone() else {
        return;
    };
    let mut agent = Agent::new(
        workspace.clone(),
        inner.model.clone(),
        provider,
        get_tools(),
        session,
        mb,
        log_tx,
    );
    std::thread::spawn(move || {
        let Ok(rt) = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
        else {
            return;
        };
        while let Ok(cmd) = cmd_rx.recv() {
            match cmd {
                GuiCmd::Shutdown => break,
                GuiCmd::Prompt { text, seq } => {
                    if let Err(e) = rt.block_on(prompt(&mut agent, text)) {
                        let _ = err_tx.send(LogLine::Dim(format!("{e:#}")));
                    }
                    let _ = done_tx.send(seq);
                }
            }
        }
    });
    inner.runs.insert(
        workspace,
        ChatRun {
            mailbox: tx,
            cmd: cmd_tx,
            log_rx,
            done_rx,
            seq: 0,
            working: false,
            error: false,
            done: false,
            draft: String::new(),
            thinking: String::new(),
            think_hide_at: None,
            queued: Vec::new(),
            steered: Vec::new(),
            last_input,
        },
    );
}

fn apply_log(inner: &mut Inner, line: LogLine) {
    match line {
        LogLine::User(text) => {
            append_item(inner, Kind::User(text), false);
        }
        LogLine::Delta(t) => {
            if let Some(id) = inner.stream_id {
                if let Some(item) = inner.items.iter_mut().find(|i| i.id == id) {
                    item.body.push_str(&t);
                }
            } else if !t.trim().is_empty() {
                if let Some(id) = append_item(inner, Kind::Agent(t), true) {
                    inner.stream_id = Some(id);
                }
            }
        }
        LogLine::Text(t) => {
            inner.stream_id = None;
            if !t.trim().is_empty() {
                append_item(inner, Kind::Agent(t), false);
            }
        }
        LogLine::Think(_) => {}
        LogLine::End => {
            if let Some(id) = inner.stream_id.take() {
                if let Some(item) = inner.items.iter_mut().find(|i| i.id == id) {
                    if item.body.trim().is_empty() {
                        inner.items.retain(|i| i.id != id);
                    } else {
                        item.streaming = false;
                    }
                }
            }
        }
        LogLine::Dim(t) => {
            append_item(inner, Kind::Note(t), false);
        }
        LogLine::Tools { runs } => {
            merge_tools(inner, runs);
        }
        LogLine::Usage(_) => {}
    }
}

fn replay(session: &Session) -> Vec<Kind> {
    let mut out = Vec::new();
    let mut i = 0;
    let entries = &session.entries;
    while i < entries.len() {
        match &entries[i] {
            Entry::User { text } => {
                out.push(Kind::User(text.clone()));
                i += 1;
            }
            Entry::Assistant { text, calls, .. } => {
                if !text.trim().is_empty() {
                    out.push(Kind::Agent(text.clone()));
                }
                if !calls.is_empty() {
                    let mut results = Vec::new();
                    let mut j = i + 1;
                    while j < entries.len() {
                        if let Entry::Tool(t) = &entries[j] {
                            results.push(t);
                            j += 1;
                        } else {
                            break;
                        }
                    }
                    let mut runs: Vec<ToolRun> = calls
                        .iter()
                        .map(|c| {
                            let res = results.iter().find(|t| t.id == c.id);
                            ToolRun {
                                name: title_case(&c.name),
                                args: args_repr(&c.args),
                                detail: match res.filter(|t| t.is_error) {
                                    Some(t) => t.content.clone(),
                                    None => String::new(),
                                },
                                is_error: res.is_some_and(|t| t.is_error),
                            }
                        })
                        .collect();
                    i = j;
                    while i < entries.len() {
                        match &entries[i] {
                            Entry::Assistant { text, calls, .. }
                                if text.trim().is_empty() && !calls.is_empty() =>
                            {
                                let mut more = Vec::new();
                                let mut k = i + 1;
                                while k < entries.len() {
                                    if let Entry::Tool(t) = &entries[k] {
                                        more.push(t);
                                        k += 1;
                                    } else {
                                        break;
                                    }
                                }
                                runs.extend(calls.iter().map(|c| {
                                    let res = more.iter().find(|t| t.id == c.id);
                                    ToolRun {
                                        name: title_case(&c.name),
                                        args: args_repr(&c.args),
                                        detail: match res.filter(|t| t.is_error) {
                                            Some(t) => t.content.clone(),
                                            None => String::new(),
                                        },
                                        is_error: res.is_some_and(|t| t.is_error),
                                    }
                                }));
                                i = k;
                            }
                            _ => break,
                        }
                    }
                    out.push(Kind::Tool(runs));
                } else {
                    i += 1;
                }
            }
            Entry::Tool(_) => i += 1,
        }
    }
    out
}

fn merge_tools(inner: &mut Inner, runs: Vec<ToolRun>) {
    if runs.is_empty() {
        return;
    }
    if let Some(block) = inner.last_tool.as_mut() {
        block.runs.extend(runs);
        let (ok, fail) = tool_counts(&block.runs);
        let summary = tool_summary(ok, fail);
        let detail = tool_detail(&block.runs);
        let id = block.item_id;
        if let Some(item) = inner.items.iter_mut().find(|i| i.id == id) {
            item.tool_summary = summary;
            item.tool_detail = detail;
        }
        return;
    }
    append_item(inner, Kind::Tool(runs), false);
}

fn tool_detail(runs: &[ToolRun]) -> String {
    let mut detail = String::new();
    for r in runs {
        if !detail.is_empty() {
            detail.push('\n');
        }
        detail.push_str(&format!("• {}", r.call_line()));
        if r.is_error && !r.detail.is_empty() {
            for line in r.detail.lines() {
                detail.push('\n');
                detail.push_str("  ");
                detail.push_str(line);
            }
        }
    }
    detail
}

fn remember_opened(inner: &mut Inner, workspace: &Path) {
    if let Some(i) = inner.opened.iter().position(|p| same_dir(p, workspace)) {
        inner.opened.remove(i);
    }
    inner.opened.insert(0, workspace.to_path_buf());
    save_opened(&inner.opened);
}

fn forget_opened(inner: &mut Inner, workspace: &Path) {
    inner.opened.retain(|p| !same_dir(p, workspace));
    save_opened(&inner.opened);
}

fn run_get<'a>(runs: &'a HashMap<PathBuf, ChatRun>, workspace: &Path) -> Option<&'a ChatRun> {
    if let Some(run) = runs.get(workspace) {
        return Some(run);
    }
    runs.iter()
        .find(|(p, _)| same_dir(p, workspace))
        .map(|(_, r)| r)
}

fn run_mut<'a>(
    runs: &'a mut HashMap<PathBuf, ChatRun>,
    workspace: &Path,
) -> Option<&'a mut ChatRun> {
    if runs.contains_key(workspace) {
        return runs.get_mut(workspace);
    }
    let key = runs.keys().find(|p| same_dir(p, workspace)).cloned();
    key.and_then(move |k| runs.get_mut(&k))
}

fn stop_run(inner: &mut Inner, workspace: &Path) {
    if let Some(run) = run_get(&inner.runs, workspace) {
        let _ = run.cmd.send(GuiCmd::Shutdown);
        run.mailbox.abort();
    }
    let key = inner.runs.keys().find(|p| same_dir(p, workspace)).cloned();
    if let Some(k) = key {
        inner.runs.remove(&k);
    }
}

fn folder_name(path: &Path) -> String {
    match path.file_name().and_then(|s| s.to_str()) {
        Some(name) => name.to_string(),
        None => "folder".into(),
    }
}

fn same_dir(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

fn one_line(s: &str) -> String {
    let line = match s.lines().map(str::trim).find(|l| !l.is_empty()) {
        Some(l) => l,
        None => s,
    };
    line.chars().take(80).collect()
}

fn format_preview(who: &str, body: &str) -> String {
    let line = match body.lines().map(str::trim).find(|s| !s.is_empty()) {
        Some(s) => s,
        None => "",
    };
    let line: String = line.chars().take(40).collect();
    if line.is_empty() {
        who.to_string()
    } else {
        format!("{who}: {line}")
    }
}

fn session_preview(session: &Session) -> String {
    for e in session.entries.iter().rev() {
        match e {
            Entry::User { text } if !text.trim().is_empty() => {
                return format_preview("You", text);
            }
            Entry::Assistant { text, .. } if !text.trim().is_empty() => {
                return format_preview("Fun", text);
            }
            _ => {}
        }
    }
    String::new()
}

fn usage_pct(tokens: u64) -> f64 {
    if tokens == 0 {
        0.0
    } else {
        (tokens as f64) * 100.0 / (CONTEXT_MAX as f64)
    }
}

fn usage_text(tokens: u64) -> String {
    format!("{:.1}% of 500k", usage_pct(tokens))
}

fn usage_tip(tokens: u64) -> String {
    format!("{tokens} / {CONTEXT_MAX} last prompt tokens")
}

fn opened_path() -> PathBuf {
    let base = match std::env::var("XDG_DATA_HOME") {
        Ok(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => match std::env::var("HOME") {
            Ok(home) if !home.is_empty() => PathBuf::from(home).join(".local/share"),
            _ => PathBuf::from("."),
        },
    };
    base.join("fun/opened.json")
}

fn load_opened() -> Vec<PathBuf> {
    let Ok(text) = std::fs::read_to_string(opened_path()) else {
        return Vec::new();
    };
    match serde_json::from_str::<Vec<String>>(&text) {
        Ok(list) => list
            .into_iter()
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
            .collect(),
        Err(_) => Vec::new(),
    }
}

fn save_opened(paths: &[PathBuf]) {
    let path = opened_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let list: Vec<String> = paths.iter().map(|p| p.display().to_string()).collect();
    if let Ok(text) = serde_json::to_string_pretty(&list) {
        let _ = std::fs::write(path, text);
    }
}
