#!/usr/bin/env python3
"""Windows tray dictation. whisper.cpp, Ctrl+V, clipboard restored.

No meeting mode, no llama, no sherpa. The Mac app's config.json is never opened.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import urllib.error
import urllib.parse
import urllib.request
import wave
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True

from PySide6.QtCore import QByteArray, QMimeData, QObject, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QColor, QIcon, QKeyEvent, QPainter, QPixmap
from PySide6.QtTest import QTest
from PySide6.QtWidgets import (
    QApplication,
    QMenu,
    QPlainTextEdit,
    QProgressDialog,
    QSystemTrayIcon,
)

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
PIN_FILE = ROOT / "PIN.txt"

CONFIG_DIR = Path.home() / ".config" / "whisper"
SETTINGS_PATH = CONFIG_DIR / "windows.json"
RUNTIME_DIR = CONFIG_DIR / "windows"

ORG = "ggml-org"
REPO_NAME = "whisper.cpp"
MODEL_ID = "tiny.en"
ALLOWED_MODELS = {"tiny.en", "base.en"}
SAMPLE_RATE = 16000

DEFAULTS = {
    "recordHotkey": "alt+space",
    "language": "en",
    "model": MODEL_ID,
    "threads": 4,
}

MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT = 0x0004
MOD_WIN = 0x0008
VK_SPACE = 0x20
CHECK_WORDS = "alpha bravo"

_checked_commit: str | None = None


def read_pin() -> str:
    tag = PIN_FILE.read_text(encoding="utf-8").strip().splitlines()[0].strip()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise SystemExit(f"bad pin in {PIN_FILE}: {tag!r}")
    return tag


def refuse_mac_config(path: Path) -> None:
    if path.name == "config.json" and path.parent == CONFIG_DIR:
        raise SystemExit("refusing to touch ~/.config/whisper/config.json")


def load_settings() -> dict:
    """Read windows.json. Create it only when it is missing. Never rewrite it."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    refuse_mac_config(SETTINGS_PATH)
    if not SETTINGS_PATH.exists():
        text = json.dumps(DEFAULTS, indent=2) + "\n"
        SETTINGS_PATH.write_text(text, encoding="utf-8")
        return dict(DEFAULTS)
    try:
        data = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"windows.json unreadable ({exc}); using defaults in memory", file=sys.stderr)
        return dict(DEFAULTS)
    out = dict(DEFAULTS)
    if isinstance(data, dict):
        for key in DEFAULTS:
            if key in data:
                out[key] = data[key]
    if out["model"] not in ALLOWED_MODELS:
        print(f"model {out['model']!r} is not a small English model; using {MODEL_ID}", file=sys.stderr)
        out["model"] = MODEL_ID
    return out


def host_ok(host: str | None) -> bool:
    host = (host or "").lower()
    if host in ("github.com", "huggingface.co"):
        return True
    return host.endswith(".github.com") or host.endswith(".githubusercontent.com") or host.endswith(".huggingface.co") or host.endswith(".hf.co")


class _GuardRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        host = urllib.parse.urlparse(newurl).hostname
        if not host_ok(host):
            raise SystemExit(f"refusing redirect to {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _opener():
    return urllib.request.build_opener(_GuardRedirect)


def fetch_json(url: str):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "whisper-windows", "Accept": "application/vnd.github+json"},
    )
    with _opener().open(req, timeout=60) as resp:
        return json.load(resp)


def confirm_release(tag: str) -> str:
    """Confirm ggml-org/whisper.cpp owns this tag. Returns the commit sha. No download yet."""
    global _checked_commit
    if _checked_commit:
        return _checked_commit
    repo = fetch_json(f"https://api.github.com/repos/{ORG}/{REPO_NAME}")
    full = repo.get("full_name")
    owner = (repo.get("owner") or {}).get("login")
    if full != f"{ORG}/{REPO_NAME}" or owner != ORG:
        raise SystemExit(f"refusing download: GitHub repo is {full!r} owner {owner!r}")
    rel = fetch_json(f"https://api.github.com/repos/{ORG}/{REPO_NAME}/releases/tags/{tag}")
    if rel.get("tag_name") != tag:
        raise SystemExit(f"refusing download: release tag is {rel.get('tag_name')!r}")
    sha = rel.get("target_commitish") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit(f"refusing download: {tag} did not resolve to a commit ({sha!r})")
    _checked_commit = sha
    return sha


def confirm_model_repo() -> None:
    meta = fetch_json("https://huggingface.co/api/models/ggerganov/whisper.cpp")
    if meta.get("id") != "ggerganov/whisper.cpp":
        raise SystemExit(f"refusing model download: Hugging Face id is {meta.get('id')!r}")


def download(url: str, dest: Path, label: str, progress) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "whisper-windows"})
    last = -1
    with _opener().open(req, timeout=120) as resp, tmp.open("wb") as out:
        total = int(resp.headers.get("Content-Length") or 0)
        got = 0
        while True:
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            out.write(chunk)
            got += len(chunk)
            # Unknown length: one tick per megabyte, not per chunk.
            mark = (got * 10 // total) if total else got // (1 << 20)
            if mark != last:
                last = mark
                progress(label, got, total)
    tmp.replace(dest)


def model_path(model_id: str) -> Path:
    return RUNTIME_DIR / f"ggml-{model_id}.bin"


def ensure_model(model_id: str, progress, gui=None) -> Path:
    path = model_path(model_id)
    if path.is_file() and path.stat().st_size > 1_000_000:
        return path
    confirm_model_repo()
    url = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{model_id}.bin"
    if not url.startswith("https://huggingface.co/ggerganov/whisper.cpp/"):
        raise SystemExit(f"refusing model url {url}")
    print(f"downloading {path.name}", flush=True)

    def tick(label, got, total):
        progress(label, got, total)
        if gui is not None and total:
            gui(got * 100 // total)

    download(url, path, path.name, tick)
    return path


def binary_path() -> Path:
    name = "whisper-cli.exe" if sys.platform == "win32" else "whisper-cli"
    return RUNTIME_DIR / name


def _asset_url(sha: str, name: str) -> str | None:
    releases = fetch_json(f"https://api.github.com/repos/{ORG}/{REPO_NAME}/releases?per_page=100")
    for rel in releases:
        if rel.get("target_commitish") != sha:
            continue
        for asset in rel.get("assets") or []:
            if asset.get("name") != name:
                continue
            url = asset.get("browser_download_url") or ""
            if f"/{ORG}/{REPO_NAME}/" not in url:
                raise SystemExit(f"refusing asset url {url}")
            return url
    return None


def _safe_extract_tar(tar_path: Path, dest: Path) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tar_path) as tf:
        root = None
        for member in tf.getmembers():
            target = (dest / member.name).resolve()
            if dest.resolve() not in target.parents and target != dest.resolve():
                raise SystemExit(f"unsafe path in tarball: {member.name}")
            if root is None and member.isdir():
                root = dest / member.name.split("/")[0]
        tf.extractall(dest, filter="data")
    if root is None or not root.is_dir():
        raise SystemExit("tarball had no root directory")
    return root


def _build_from_tag(tag: str, progress) -> Path:
    url = f"https://github.com/{ORG}/{REPO_NAME}/archive/refs/tags/{tag}.tar.gz"
    tarball = RUNTIME_DIR / f"whisper.cpp-{tag}.tar.gz"
    src_root = RUNTIME_DIR / "src"
    print(f"downloading {tag} source (no macOS CLI zip on the release)", flush=True)
    download(url, tarball, f"{tag}.tar.gz", progress)
    if src_root.exists():
        shutil.rmtree(src_root)
    src = _safe_extract_tar(tarball, src_root)
    build = src / "build"
    print("building whisper-cli", flush=True)
    configure = [
        "cmake", "-S", str(src), "-B", str(build),
        "-DCMAKE_BUILD_TYPE=Release",
        "-DWHISPER_BUILD_TESTS=OFF",
        "-DWHISPER_BUILD_SERVER=OFF",
        "-DWHISPER_SDL2=OFF",
        "-DGGML_METAL=OFF",
        "-DGGML_BLAS=OFF",
        "-DBUILD_SHARED_LIBS=OFF",
    ]
    log = RUNTIME_DIR / "build.log"
    build_cmd = ["cmake", "--build", str(build), "--target", "whisper-cli"]
    # Visual Studio is multi-config and defaults to Debug unless this is set.
    if sys.platform == "win32":
        build_cmd += ["--config", "Release"]
    build_cmd += ["-j", str(os.cpu_count() or 4)]
    with log.open("w", encoding="utf-8") as fh:
        subprocess.run(configure, check=True, stdout=fh, stderr=subprocess.STDOUT)
        subprocess.run(build_cmd, check=True, stdout=fh, stderr=subprocess.STDOUT)
    found = _find_cli(build)
    if found is None:
        raise SystemExit(f"whisper-cli was not produced; see {log}")
    dest = _publish_cli(found)
    shutil.rmtree(src_root, ignore_errors=True)
    tarball.unlink(missing_ok=True)
    log.unlink(missing_ok=True)
    return dest


def _windows_asset_name() -> str:
    machine = platform.machine().lower()
    if machine in ("arm64", "aarch64"):
        return "whisper-bin-win-cpu-arm64.zip"
    return "whisper-bin-x64.zip"


def _install_windows_zip(url: str, progress) -> Path:
    zip_path = RUNTIME_DIR / "whisper-bin.zip"
    unpack = RUNTIME_DIR / "pkg"
    download(url, zip_path, "whisper-cli.zip", progress)
    if unpack.exists():
        shutil.rmtree(unpack)
    unpack.mkdir(parents=True)
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            target = (unpack / info.filename).resolve()
            if unpack.resolve() not in target.parents and target != unpack.resolve():
                raise SystemExit(f"unsafe path in zip: {info.filename}")
        zf.extractall(unpack)
    found = _find_cli(unpack)
    if found is None:
        raise SystemExit("windows zip had no whisper-cli.exe")
    # Copy the exe and its DLLs. A symlink needs Windows Developer Mode.
    dest = _publish_cli(found)
    shutil.rmtree(unpack, ignore_errors=True)
    zip_path.unlink(missing_ok=True)
    return dest


def _find_cli(root: Path) -> Path | None:
    """The built tool is whisper-cli on macOS and whisper-cli.exe on Windows."""
    names = {"whisper-cli", "whisper-cli.exe"}
    found = [p for p in root.rglob("*") if p.is_file() and p.name.lower() in names]
    exes = [p for p in found if p.suffix.lower() == ".exe"]
    pool = exes or [p for p in found if os.access(p, os.X_OK)]
    if not pool:
        return None

    def rank(path: Path) -> tuple:
        parts = [part.lower() for part in path.parts]
        if "release" in parts:
            config = 0
        elif "debug" in parts:
            config = 2
        else:
            config = 1
        return (config, len(path.parts))

    pool.sort(key=rank)
    return pool[0]


def _publish_cli(found: Path) -> Path:
    """Copy the tool to the stable runtime path. DLLs stay beside the exe."""
    dest = binary_path()
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    try:
        same = found.resolve() == dest.resolve()
    except OSError:
        same = False
    if dest.is_symlink() or (dest.exists() and not same):
        dest.unlink()
    if not same:
        shutil.copy2(found, dest)
        if sys.platform == "win32":
            for item in found.parent.iterdir():
                if item.is_file() and item.suffix.lower() == ".dll":
                    shutil.copy2(item, RUNTIME_DIR / item.name)
    if sys.platform != "win32":
        dest.chmod(0o755)
    subprocess.run([str(dest), "--version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return dest


def ensure_binary(tag: str, progress) -> Path:
    dest = binary_path()
    stamp = RUNTIME_DIR / "binary-tag"
    if dest.exists() and stamp.is_file() and stamp.read_text(encoding="utf-8").strip() == tag:
        return dest.resolve()
    sha = confirm_release(tag)
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    if sys.platform == "win32":
        url = _asset_url(sha, _windows_asset_name())
        if url:
            path = _install_windows_zip(url, progress)
            stamp.write_text(tag + "\n", encoding="utf-8")
            return path
    path = _build_from_tag(tag, progress)
    stamp.write_text(tag + "\n", encoding="utf-8")
    return path


def assert_outside_repo(path: Path) -> None:
    resolved = path.resolve()
    repo = REPO.resolve()
    config = CONFIG_DIR.resolve()
    if repo == resolved or repo in resolved.parents:
        raise SystemExit(f"{resolved} is inside the git repo")
    if config != resolved and config not in resolved.parents:
        raise SystemExit(f"{resolved} is not under {config}")


def write_wav(path: Path, samples, sample_rate: int) -> None:
    import numpy as np

    data = np.asarray(samples, dtype=np.int16).reshape(-1)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(data.tobytes())


def _to_16k_int16(audio, sample_rate: int):
    import numpy as np

    x = np.asarray(audio, dtype=np.float32).reshape(-1)
    if sample_rate != SAMPLE_RATE and x.size:
        n = int(round(x.size * SAMPLE_RATE / sample_rate))
        src_x = np.linspace(0, 1, num=x.size, endpoint=False)
        dst_x = np.linspace(0, 1, num=max(n, 1), endpoint=False)
        x = np.interp(dst_x, src_x, x).astype(np.float32)
    y = np.clip(x, -1, 1)
    return (y * 32767.0).astype(np.int16)


def record_seconds(seconds: float):
    import sounddevice as sd

    try:
        audio = sd.rec(int(seconds * SAMPLE_RATE), samplerate=SAMPLE_RATE, channels=1, dtype="float32")
        sd.wait()
        rate = SAMPLE_RATE
    except sd.PortAudioError:
        info = sd.query_devices(sd.default.device[0], "input")
        rate = int(info["default_samplerate"])
        audio = sd.rec(int(seconds * rate), samplerate=rate, channels=1, dtype="float32")
        sd.wait()
    return _to_16k_int16(audio, rate)


def transcribe(binary: Path, model: Path, wav: Path, threads: int, language: str) -> str:
    out_base = wav.with_suffix("")
    txt = Path(str(out_base) + ".txt")
    txt.unlink(missing_ok=True)
    cmd = [
        str(binary),
        "-m", str(model),
        "-f", str(wav),
        "-l", language,
        "-t", str(int(threads)),
        "-nt",
        "-np",
        "-ng",
        "-otxt",
        "-of", str(out_base),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise RuntimeError(detail or f"whisper-cli exit {proc.returncode}")
    if txt.is_file():
        text = txt.read_text(encoding="utf-8", errors="replace")
        txt.unlink(missing_ok=True)
    else:
        text = proc.stdout
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return " ".join(lines).strip()


def snapshot_clipboard(cb) -> list[tuple[str, bytes]]:
    mime = cb.mimeData()
    if mime is None:
        return []
    return [(fmt, bytes(mime.data(fmt))) for fmt in mime.formats()]


def restore_clipboard(cb, items: list[tuple[str, bytes]]) -> None:
    mime = QMimeData()
    for fmt, data in items:
        mime.setData(fmt, QByteArray(data))
    cb.setMimeData(mime)


def clipboard_covers(original: list[tuple[str, bytes]], after: list[tuple[str, bytes]]) -> bool:
    got = dict(after)
    return all(got.get(fmt) == data for fmt, data in original)


def send_ctrl_v() -> None:
    if os.environ.get("WHISPER_CHECK") == "1":
        raise RuntimeError("check tried to paste into the focused app")
    if sys.platform != "win32":
        raise RuntimeError("OS Ctrl+V is the Windows paste path")
    import ctypes

    user32 = ctypes.windll.user32
    vk_control, vk_v, keyup = 0x11, 0x56, 0x0002
    user32.keybd_event(vk_control, 0, 0, 0)
    user32.keybd_event(vk_v, 0, 0, 0)
    user32.keybd_event(vk_v, 0, keyup, 0)
    user32.keybd_event(vk_control, 0, keyup, 0)


class PasteField(QPlainTextEdit):
    """A text field that pastes on Ctrl+V, which is what Notepad does."""

    def keyPressEvent(self, event):
        ctrl = bool(event.modifiers() & Qt.KeyboardModifier.ControlModifier)
        if ctrl and event.key() == Qt.Key.Key_V:
            self.insertPlainText(QApplication.clipboard().text())
            return
        super().keyPressEvent(event)


def paste_text(text: str, widget: QPlainTextEdit | None = None) -> None:
    """Put `text` on the clipboard, deliver Ctrl+V, then put the old clipboard back.

    A widget is the check's own field. Without one, this posts Ctrl+V to the
    foreground window (Windows only) and restores 350ms later, same as the Mac app.
    """
    cb = QApplication.clipboard()
    saved = snapshot_clipboard(cb)
    cb.setText(text)
    if widget is not None:
        QTest.keyClick(widget, Qt.Key.Key_V, Qt.KeyboardModifier.ControlModifier)
        restore_clipboard(cb, saved)
        QApplication.processEvents()
        return
    send_ctrl_v()

    def later():
        restore_clipboard(cb, saved)

    QTimer.singleShot(350, later)


def parse_hotkey(spec: str) -> tuple[int, int]:
    mods = 0
    key = None
    for part in spec.lower().split("+"):
        part = part.strip()
        if not part:
            continue
        if part in ("alt", "opt", "option"):
            mods |= MOD_ALT
        elif part in ("ctrl", "control"):
            mods |= MOD_CONTROL
        elif part == "shift":
            mods |= MOD_SHIFT
        elif part in ("win", "super", "cmd", "command"):
            mods |= MOD_WIN
        else:
            if key is not None:
                raise ValueError(f"bad hotkey {spec!r}")
            key = part
    if key is None:
        raise ValueError(f"bad hotkey {spec!r}")
    if key == "space":
        vk = VK_SPACE
    elif len(key) == 1 and key.isascii() and key.isalnum():
        vk = ord(key.upper())
    else:
        raise ValueError(f"bad hotkey {spec!r}")
    return mods, vk


class HotkeyThread(threading.Thread):
    """Windows RegisterHotKey. Not started on macOS, and never started by --check."""

    def __init__(self, spec: str, callback):
        super().__init__(name="whisper-hotkey", daemon=True)
        self.mods, self.vk = parse_hotkey(spec)
        self.callback = callback
        self._stop = threading.Event()

    def run(self):
        if sys.platform != "win32":
            return
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.windll.user32
        hotkey_id = 1
        if not user32.RegisterHotKey(None, hotkey_id, self.mods, self.vk):
            print("RegisterHotKey failed", file=sys.stderr)
            return
        msg = wintypes.MSG()
        try:
            while not self._stop.is_set():
                rc = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
                if rc in (0, -1):
                    break
                if msg.message == 0x0312:  # WM_HOTKEY
                    self.callback()
        finally:
            user32.UnregisterHotKey(None, hotkey_id)

    def stop(self):
        self._stop.set()
        if sys.platform == "win32" and self.ident:
            import ctypes
            ctypes.windll.user32.PostThreadMessageW(self.ident, 0x0012, 0, 0)  # WM_QUIT


def hide_dock_icon() -> None:
    """Accessory policy so a tray run does not take the Dock. No-op if it cannot."""
    if sys.platform != "darwin":
        return
    try:
        import ctypes

        ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
        objc = ctypes.cdll.LoadLibrary("/usr/lib/libobjc.A.dylib")
        objc.objc_getClass.argtypes = [ctypes.c_char_p]
        objc.objc_getClass.restype = ctypes.c_void_p
        objc.sel_registerName.argtypes = [ctypes.c_char_p]
        objc.sel_registerName.restype = ctypes.c_void_p
        # Call the loaded objc_msgSend with argtypes set. A CFUNCTYPE cast crashes.
        send = objc.objc_msgSend
        send.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        send.restype = ctypes.c_void_p
        nsapp = send(objc.objc_getClass(b"NSApplication"), objc.sel_registerName(b"sharedApplication"))
        if not nsapp:
            return
        send.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long]
        send.restype = ctypes.c_bool
        send(nsapp, objc.sel_registerName(b"setActivationPolicy:"), 1)
    except (OSError, AttributeError):
        return


def tray_icon() -> QIcon:
    pix = QPixmap(22, 22)
    pix.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pix)
    painter.setBrush(QColor("#e8e8e8"))
    painter.setPen(Qt.PenStyle.NoPen)
    painter.drawEllipse(4, 4, 14, 14)
    painter.end()
    return QIcon(pix)


def mic_auth() -> str:
    """AVFoundation status without requesting permission. not_determined is not a prompt."""
    if sys.platform != "darwin":
        return "unknown"
    swift = shutil.which("swift")
    if not swift:
        return "unknown"
    code = (
        "import AVFoundation\n"
        "print(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)\n"
    )
    proc = subprocess.run([swift, "-e", code], capture_output=True, text=True, timeout=90)
    if proc.returncode != 0:
        return "unknown"
    raw = proc.stdout.strip()
    return {"0": "not_determined", "1": "restricted", "2": "denied", "3": "authorized"}.get(raw, "unknown")


def _progress_print(label: str, got: int, total: int) -> None:
    if total:
        print(f"{label}: {got * 100 // total}%", flush=True)
    else:
        print(f"{label}: {got} bytes", flush=True)


class _Bridge(QObject):
    fired = Signal()
    done = Signal(str)


class Tray:
    def __init__(self, app: QApplication):
        self.app = app
        self.settings = load_settings()
        self.listening = False
        self.stream = None
        self.frames: list = []
        self.bridge = _Bridge()
        self.bridge.fired.connect(self.toggle)
        self.bridge.done.connect(self._paste_result)
        hide_dock_icon()
        self.tray = QSystemTrayIcon(tray_icon())
        self.tray.setToolTip("Whisper")
        menu = QMenu()
        hotkey = str(self.settings["recordHotkey"])
        label = QAction(f"Hotkey {hotkey}")
        label.setEnabled(False)
        menu.addAction(label)
        quit_action = menu.addAction("Quit")
        quit_action.triggered.connect(self.quit)
        self.tray.setContextMenu(menu)
        self.tray.show()
        self._prepare()
        self.hotkey = HotkeyThread(hotkey, self.bridge.fired.emit)
        self.hotkey.start()

    def _prepare(self) -> None:
        dlg = QProgressDialog("Preparing Whisper", None, 0, 0)
        dlg.setWindowTitle("Whisper")
        dlg.setCancelButton(None)
        dlg.setMinimumDuration(0)
        dlg.show()
        QApplication.processEvents()

        def gui(pct: int) -> None:
            dlg.setMaximum(100)
            dlg.setValue(pct)
            QApplication.processEvents()

        tag = read_pin()
        self.binary = ensure_binary(tag, _progress_print)
        self.model = ensure_model(self.settings["model"], _progress_print, gui)
        dlg.close()

    def toggle(self) -> None:
        if self.listening:
            self._stop_and_paste()
        else:
            self._start()

    def _start(self) -> None:
        import sounddevice as sd

        self.frames = []

        def on_audio(indata, frames, time_info, status):
            self.frames.append(indata.copy())

        self.stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="float32", callback=on_audio
        )
        self.stream.start()
        self.listening = True
        self.tray.setToolTip("Whisper: listening")

    def _stop_and_paste(self) -> None:
        import numpy as np

        stream, self.stream = self.stream, None
        self.listening = False
        self.tray.setToolTip("Whisper")
        if stream is not None:
            stream.stop()
            stream.close()
        if not self.frames:
            return
        audio = np.concatenate(self.frames, axis=0)
        self.frames = []
        pcm = _to_16k_int16(audio, SAMPLE_RATE)
        if pcm.size < int(SAMPLE_RATE * 0.3):
            return
        wav = RUNTIME_DIR / "take.wav"

        def work():
            try:
                write_wav(wav, pcm, SAMPLE_RATE)
                text = transcribe(
                    self.binary, self.model, wav,
                    int(self.settings["threads"]), str(self.settings["language"]),
                )
            except Exception as exc:
                text = ""
                print(f"transcribe failed: {exc}", file=sys.stderr)
            finally:
                wav.unlink(missing_ok=True)
            self.bridge.done.emit(text)

        threading.Thread(target=work, name="whisper-transcribe", daemon=True).start()

    def _paste_result(self, text: str) -> None:
        if text:
            paste_text(text)

    def quit(self) -> None:
        if self.listening:
            stream, self.stream = self.stream, None
            self.listening = False
            if stream is not None:
                stream.stop()
                stream.close()
        self.hotkey.stop()
        self.hotkey.join(timeout=1)
        self.app.quit()


def _recording_check(binary: Path, model: Path, settings: dict) -> bool:
    """True if the live mic path was run. A missing or refused mic is a skip."""
    auth = mic_auth()
    if sys.platform == "darwin" and auth != "authorized":
        if auth in ("denied", "restricted"):
            print(f"RECORDING SKIP: mic permission {auth}")
        elif auth == "not_determined":
            print("RECORDING SKIP: mic permission not determined (not prompting)")
        else:
            print("RECORDING SKIP: could not read mic permission without prompting")
        return False
    try:
        import sounddevice as sd
        idx = sd.default.device[0]
        if idx is None or int(idx) < 0:
            print("RECORDING SKIP: no default input device")
            return False
    except Exception as exc:
        message = str(exc).lower()
        if "device" in message or "permission" in message or "authorized" in message:
            print(f"RECORDING SKIP: {exc}")
            return False
        print(f"RECORDING FAIL: {exc}", file=sys.stderr)
        raise
    try:
        pcm = record_seconds(0.6)
    except Exception as exc:
        message = str(exc).lower()
        if any(word in message for word in ("permission", "authorized", "device", "input", "-9986")):
            print(f"RECORDING SKIP: {exc}")
            return False
        print(f"RECORDING FAIL: {exc}", file=sys.stderr)
        raise
    wav = RUNTIME_DIR / "check-take.wav"
    try:
        write_wav(wav, pcm, SAMPLE_RATE)
        text = transcribe(binary, model, wav, int(settings["threads"]), str(settings["language"]))
    finally:
        wav.unlink(missing_ok=True)
        Path(str(wav.with_suffix("")) + ".txt").unlink(missing_ok=True)
    print(f"RECORDING OK: samples={int(pcm.size)} transcript={text!r}")
    return True


def run_check() -> int:
    os.environ["WHISPER_CHECK"] = "1"
    app = QApplication([])
    app.setQuitOnLastWindowClosed(False)
    hide_dock_icon()
    settings = load_settings()
    mods, vk = parse_hotkey(str(settings["recordHotkey"]))
    if (mods, vk) != (MOD_ALT, VK_SPACE) and settings["recordHotkey"] == DEFAULTS["recordHotkey"]:
        print(f"HOTKEY FAIL: {settings['recordHotkey']!r} parsed as {(mods, vk)}", file=sys.stderr)
        return 1

    tag = read_pin()
    app.processEvents()
    cb = app.clipboard()
    before_items = snapshot_clipboard(cb)
    before_text = cb.text()
    field = PasteField()
    field.setAttribute(Qt.WidgetAttribute.WA_DontShowOnScreen, True)
    field.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
    field.show()
    try:
        paste_text(CHECK_WORDS, widget=field)
        got = field.toPlainText()
        after_items = snapshot_clipboard(cb)
        after_text = cb.text()
        if got != CHECK_WORDS:
            print(f"CLIPBOARD FAIL: field has {got!r}", file=sys.stderr)
            return 1
        if after_text != before_text or not clipboard_covers(before_items, after_items):
            print(
                f"CLIPBOARD FAIL: text {before_text!r} -> {after_text!r}",
                file=sys.stderr,
            )
            restore_clipboard(cb, before_items)
            return 1
    finally:
        field.close()
        if app.clipboard().text() != before_text:
            restore_clipboard(app.clipboard(), before_items)

    try:
        binary = ensure_binary(tag, _progress_print)
        model = ensure_model(str(settings["model"]), _progress_print)
        assert_outside_repo(binary)
        assert_outside_repo(model)
    except (SystemExit, subprocess.CalledProcessError, OSError, RuntimeError, urllib.error.URLError) as exc:
        log = RUNTIME_DIR / "build.log"
        if log.is_file():
            lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
            print("\n".join(lines[-40:]), file=sys.stderr)
        print(f"RUNTIME FAIL: {exc}", file=sys.stderr)
        return 1

    hotkeys = [t for t in threading.enumerate() if t.name == "whisper-hotkey"]
    if hotkeys:
        print("HOTKEY FAIL: listener still running", file=sys.stderr)
        return 1
    if shutil.which("pgrep"):
        listed = subprocess.run(["pgrep", "-lf", "sherpa"], capture_output=True, text=True)
        if listed.stdout.strip():
            print(f"SHERPA FAIL:\n{listed.stdout}", file=sys.stderr)
            return 1

    try:
        _recording_check(binary, model, settings)
    except Exception:
        return 1

    print(f"PIN {tag}")
    print(f"BINARY {binary}")
    print(f"MODEL {model}")
    print("CLIPBOARD OK")
    print("CHECK OK")
    return 0


def run_tray() -> int:
    if "--meeting" in sys.argv:
        print("meeting mode is not in this build", file=sys.stderr)
        return 2
    app = QApplication([])
    app.setQuitOnLastWindowClosed(False)
    Tray(app)
    return app.exec()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Windows Whisper tray")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--meeting", action="store_true")
    args = parser.parse_args(argv)
    if args.meeting:
        print("meeting mode is not in this build", file=sys.stderr)
        return 2
    if args.check:
        return run_check()
    return run_tray()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(130)
