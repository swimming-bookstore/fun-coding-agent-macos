# Fun coding agent macOS

Native Mac window for Fun coding agent. Shares `fun-core` with the CLI and GTK 4 app. Layout follows [connect-client-macos](https://github.com/swimming-bookstore/connect-client-macos): agent, tools, and sessions in Rust, SwiftUI only for the window.

```
rust/          UniFFI crate (fun-core, Grok login, rooms)
macos/         SwiftUI app + Generated bindings
```

```sh
# login still lives in the CLI
cargo install --git https://github.com/swimming-bookstore/fun-coding-agent --bin fun
fun login

open macos/Fun.xcodeproj
```

Run the `Fun` scheme (macOS 14+, Xcode, `rustup` with Mac targets). Xcode builds the Rust core first (`rust/scripts/build-macos.sh`) into `macos/Fun/Generated/`. Same script works from a terminal.

Uses the same config, auth, and sessions as `fun`:

- Config: `~/.config/fun/config.json`
- Auth: `~/.local/share/fun/auth.json`
- Sessions: `~/.local/share/fun/sessions/`

Depends on `fun-core` and `provider-grok` from https://github.com/swimming-bookstore/fun-coding-agent (not a local checkout).

Not sandboxed — the agent reads and writes the folders you open, same as the CLI.
