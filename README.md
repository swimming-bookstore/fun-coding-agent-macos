# Fun coding agent macOS

Native Mac window for Fun coding agent. Shares `fun-core` with the CLI and GTK 4 app. Layout follows [connect-client-macos](https://github.com/swimming-bookstore/connect-client-macos): agent, tools, and sessions in Rust, SwiftUI only for the window.

```
gui-core/      UniFFI crate (agent, tools, sessions, Grok login)
macos/         SwiftUI app + Generated bindings
```

```sh
# login still lives in the CLI
cargo install --git https://github.com/swimming-bookstore/fun-coding-agent --bin fun
fun login

open macos/Fun.xcodeproj
```

Run the `Fun` scheme (macOS 14+, Xcode, `rustup` with Mac targets). Xcode builds `gui-core` first (`scripts/build-core.sh`) into `macos/Fun/Generated/`. Same script works from a terminal.

Uses the same config, auth, and sessions as `fun`:

- Config: `~/.config/fun/config.json`
- Auth: `~/.local/share/fun/auth.json`
- Sessions: `~/.local/share/fun/sessions/`

Depends on `fun-core` and `provider-grok` from https://github.com/swimming-bookstore/fun-coding-agent.

Not sandboxed — the agent reads and writes the folders you open, same as the CLI.

`python3 scripts/record-demo.py` writes `demo/demo.mp4` (needs `fun login`, Xcode, and a live Grok session).
