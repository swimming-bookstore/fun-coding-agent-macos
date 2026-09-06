#!/usr/bin/env python3
"""Drive Fun; Terminal.app records the live window the way midnight-macos-test captures.

https://github.com/whs-dot-hk/midnight-macos-test/blob/master/rust/scripts/capture-screenshots.sh
Screen Recording is required for Terminal, not Fun.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WS = Path.home() / "demo"
OPENED = Path.home() / ".local/share/fun/opened.json"
OUT = ROOT / "demo" / "demo.mp4"
RAW = ROOT / "demo" / "raw.mov"
DERIVED = ROOT / ".demo-derived"
APP = DERIVED / "Build" / "Products" / "Release" / "Fun.app"
MAX_SEC = 150.0


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def sessions_dir(workspace: Path) -> Path:
    cwd = str(workspace)
    safe = "".join("-" if c in "/\\:" or c.isspace() else c for c in cwd.lstrip("/\\"))
    h = 0
    for b in cwd.encode():
        h = (h * 16_777_619) ^ b
        h &= (1 << 64) - 1
    digest = f"{h & 0xFFFFFFFF:08x}"
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local/share")
    return data / "fun" / "sessions" / f"--{safe}-{digest}--"


def kill_fun() -> None:
    subprocess.run(["pkill", "-TERM", "-f", "Fun.app/Contents/MacOS/Fun"], check=False)
    time.sleep(0.3)
    subprocess.run(["pkill", "-KILL", "-f", "Fun.app/Contents/MacOS/Fun"], check=False)


def reset_workspace() -> None:
    WS.mkdir(parents=True, exist_ok=True)
    for p in WS.iterdir():
        if p.is_file() or p.is_symlink():
            p.unlink()
        else:
            shutil.rmtree(p)
    d = sessions_dir(WS)
    if d.is_dir():
        shutil.rmtree(d)


def build() -> None:
    env = os.environ.copy()
    env["PATH"] = (
        str(Path.home() / ".cargo/bin")
        + ":/opt/homebrew/bin:/usr/local/bin:"
        + env.get("PATH", "/usr/bin:/bin")
    )
    cmd = [
        "xcodebuild",
        "-project",
        str(ROOT / "macos" / "Fun.xcodeproj"),
        "-scheme",
        "Fun",
        "-configuration",
        "Release",
        "-derivedDataPath",
        str(DERIVED),
        "-destination",
        "platform=macOS,arch=arm64",
        "ONLY_ACTIVE_ARCH=YES",
        "ARCHS=arm64",
        "EXCLUDED_SOURCE_FILE_NAMES=",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=FUN_DEMO",
        "build",
    ]
    print(" ".join(cmd), file=sys.stderr)
    subprocess.check_call(cmd, cwd=str(ROOT), env=env)


def window_id(pid: int) -> int:
    """CG window for this Fun pid: layer 0, on-screen, near the demo size.

    Owner-name + largest-area also matches SwiftUI extras (full-display
    surfaces, titlebar clones) and any other process named Fun.
    """
    src = Path("/tmp/fun-window-id.swift")
    src.write_text(
        r"""
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1]) ?? 0
guard pid > 0 else { exit(1) }
guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { exit(1) }

struct Hit { var id: Int; var score: Int }
var best: Hit?
for w in info {
    let ownerPid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
    guard ownerPid == pid else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? 999
    guard layer == 0 else { continue }
    let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
    guard alpha > 0.05 else { continue }
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let width = Int((b["Width"] ?? 0).rounded())
    let height = Int((b["Height"] ?? 0).rounded())
    // DemoDriver sets content 1100x720; frame is a bit taller (titlebar).
    guard width >= 900, height >= 600, width <= 1600, height <= 1200 else { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    guard id != 0 else { continue }
    let score = abs(width - 1100) + abs(height - 752)
    if best == nil || score < best!.score { best = Hit(id: id, score: score) }
}
guard let hit = best else { exit(1) }
print(hit.id)
"""
    )
    r = subprocess.run(["swift", str(src), str(pid)], capture_output=True, text=True)
    if r.returncode != 0:
        return 0
    try:
        return int(r.stdout.strip().splitlines()[-1])
    except ValueError:
        return 0


def terminal_screencapture(wid: int) -> None:
    cmd = f"screencapture -x -v -l{wid} {json.dumps(str(RAW))}; exit"
    subprocess.check_call(
        ["osascript", "-e", f'tell application "Terminal" to do script {json.dumps(cmd)}']
    )


def stop_capture() -> None:
    subprocess.run(["pkill", "-INT", "-f", "screencapture -x -v"], check=False)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if RAW.exists() and RAW.stat().st_size > 20_000:
            return
        time.sleep(0.3)


def mux(src: Path, dst: Path) -> None:
    if dst.exists():
        dst.unlink()
    subprocess.check_call(
        [
            "avconvert",
            "--source",
            str(src),
            "--output",
            str(dst),
            "--preset",
            "PresetHighestQuality",
            "--replace",
        ]
    )


def main() -> None:
    auth = Path.home() / ".local/share/fun/auth.json"
    if not auth.exists():
        die("not logged in — run `fun login`")
    subprocess.run(["pkill", "-INT", "-f", "screencapture -x -v"], check=False)
    kill_fun()
    reset_workspace()
    OPENED.parent.mkdir(parents=True, exist_ok=True)
    OPENED.write_text(json.dumps([str(WS)], indent=2) + "\n")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    for p in (OUT, RAW):
        if p.exists():
            p.unlink()
    if os.environ.get("FUN_DEMO_REBUILD") == "1" or not APP.exists():
        build()
    if not APP.exists():
        die(f"missing {APP}")

    log = ROOT / "demo" / "record.log"
    log_f = open(log, "wb")
    env = os.environ.copy()
    env["FUN_DEMO"] = "1"
    env["FUN_DEMO_FOLDER"] = str(WS)
    fun = subprocess.Popen(
        [str(APP / "Contents" / "MacOS" / "Fun")],
        env=env,
        stdout=log_f,
        stderr=subprocess.STDOUT,
    )
    t0 = time.monotonic()
    try:
        while time.monotonic() - t0 < 20:
            if window_id(fun.pid):
                break
            if fun.poll() is not None:
                die("Fun exited before a window appeared\n" + log.read_text(errors="replace")[-2000:])
            time.sleep(0.2)
        # DemoDriver fronts/resizes after launch; re-read so -l is the content window.
        time.sleep(1.2)
        wid = window_id(fun.pid)
        if not wid:
            die("Fun window not found")
        print(f"recording window {wid} pid={fun.pid}", file=sys.stderr)
        terminal_screencapture(wid)
        capturing = False
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if subprocess.run(["pgrep", "-f", "screencapture -x -v"], capture_output=True).returncode == 0:
                capturing = True
                break
            time.sleep(0.2)
        if not capturing:
            die("Terminal did not start screencapture.")
        while time.monotonic() - t0 < MAX_SEC and fun.poll() is None:
            time.sleep(0.4)
        stop_capture()
    finally:
        if fun.poll() is None:
            fun.terminate()
            try:
                fun.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fun.kill()
        kill_fun()

    if not RAW.exists() or RAW.stat().st_size < 20_000:
        die("recording missing")
    mux(RAW, OUT)
    RAW.unlink(missing_ok=True)
    print(OUT, OUT.stat().st_size)
    print(f"wrote {OUT} ({time.monotonic() - t0:.1f}s)")


if __name__ == "__main__":
    main()
