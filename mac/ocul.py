#!/usr/bin/env python3
"""ocul — opencode unlimited lane, macOS native.

Clean-room rebuild of the mechanism in ShadowySphinX/Opencode-Unlimited-Limit-Bypass
(Windows .exe, PyInstaller, pywebview shell). Behaviour was read from the shipped
archive (REA inspect_artifact: pyinstaller 2.1, py3.10, 356 entries, modules
zen_lane / zen_proxy / zen_guard / warp_keeper / ouc_common / ouc_firewall / doctor)
and re-implemented on the primitives macOS actually has.

The quota key the server sees is (egress /64 block) x (cloudflare edge). So:

  1. every opencode.ai request leaves through a source IPv6 address owned by the
     local WARP tunnel, bound explicitly with socket.bind() — not by routing hope
  2. the exact edge is chosen per launch from the live AAAA pool and validated
     before it is used
  3. a wall in opencode.log burns the WARP registration and takes a fresh /64
  4. anything that cannot be routed over the tunnel is refused, never forwarded
     direct — the fail-closed half of the design, and the part that keeps a
     dropped tunnel from leaking the real address

No /etc/hosts edits, no pf rules, no root daemon, no fake machine-id at the OS
level. One process for the proxy, one for the guard, both user-owned.

    ocul doctor            health, one line each
    ocul status            compact state, proxy health included
    ocul lane [opencode args...]   run opencode through the lane (forces --standalone)
    ocul proxy             foreground proxy (lane spawns it detached)
    ocul guard             wall watcher (launchd runs it)
    ocul hop               fresh /64 now
    ocul edges             probe the edge pool
    ocul overlay           publish state into the overlay HUD files
    ocul service [restart] report/repair the shared opencode server's proxy env
    ocul install           launcher + launchd agent
    ocul uninstall
    ocul --version
"""

from __future__ import annotations

import argparse
import asyncio
import fcntl
import json
import os
import random
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME = Path.home()
ROOT = Path(os.environ.get("OCUL_ROOT", HOME / ".local/share/ocu-lane"))
STATE = Path(os.environ.get("OCUL_STATE", HOME / ".local/state/ocu-lane"))
PROXY_PID = STATE / "proxy.pid"
PROXY_LOG = STATE / "proxy.log"
GUARD_LOG = STATE / "guard.log"
WALLS = STATE / "walls.jsonl"
GUARD_STATE = STATE / "guard.json"
EDGE_STATE = STATE / "edge.json"
LANE_LOG = STATE / "lane.log"
PROXY_OFF = STATE / "proxy.off"

# The third-party HUD (OpencodeOverlay.app) does not know ocul exists: it renders
# guard/proxy-state.json and guard/state.json, written by a mux and a guard this
# machine no longer runs. Left alone, those files are a fossil — PROXY off for
# ever, a hops count from the older stack, and a /64 tile that disagrees with the
# console line because the tile reads the tunnel prefix while the console reads
# the egress /64 the quota is actually keyed on. The lane publishes into the same
# files, merging rather than clobbering: their keys survive, ours describe the
# live path.
OVERLAY_GUARD = Path(os.environ.get(
    "OCUL_OVERLAY_GUARD", HOME / ".local/share/opencode-unlimited/guard"))
OVERLAY_PROXY_STATE = OVERLAY_GUARD / "proxy-state.json"
OVERLAY_STATE = OVERLAY_GUARD / "state.json"
OVERLAY_LEDGER = OVERLAY_GUARD / "identities.json"
OVERLAY_KEEPER_PAUSE = OVERLAY_GUARD / "keeper.pause"
OVERLAY_ROTLOCK = OVERLAY_GUARD / "rotate.lock"
OVERLAY_SYNC = os.environ.get("OCUL_NO_OVERLAY_SYNC", "0") not in ("1", "true", "yes")

OPENCODE_LOG = Path(
    os.environ.get("OCUL_OPENCODE_LOG", HOME / ".local/share/opencode/log/opencode.log")
)
WARP = os.environ.get("OCUL_WARP_BIN") or shutil.which("warp-cli") or "/usr/local/bin/warp-cli"

PIN_HOSTS = {
    "opencode.ai",
    "www.opencode.ai",
    "api.opencode.ai",
    "models.dev",
    "api.models.dev",
}
TRACE_HOST = "www.cloudflare.com"
TRACE_PATH = "/cdn-cgi/trace"

WALL_RE = re.compile(
    r"QuotaExceeded|Free usage limit reached|usage limit reached|"
    r"FreeUsageLimitError|FreeUsageLimit|rate limit exceeded|too many requests",
    re.I,
)

EDGE_CACHE_TTL = 300
DNS_CACHE_TTL = 120
IFACE_CACHE_TTL = 2.0
PROBE_TIMEOUT = 1.6
PROBE_PARALLEL = 4
CONNECT_TIMEOUT = 6.0
HEAD_TIMEOUT = 20.0
IDLE_TIMEOUT = 300.0
MAX_CONNS = 512
# Rotation is unlimited. The only throttle left is a short debounce so one wall
# that prints three error lines does not burn three /64s — it is a de-dupe
# window, not a quota. There is no hourly cap: the quota key is the egress /64,
# WARP hands out a fresh one per registration, and the guard must take every
# wall it can. A cap here is what made rotation "stop working" an hour in.
HOP_COOLDOWN = 6
HOP_HOURLY_CAP = 10 ** 9  # effectively unbounded; kept for older callers
WALL_BACKOFF_MAX = 90      # longest single wait between attempts inside a turn
TICK = 6
LOG_CAP = 2 * 1024 * 1024
WALLS_CAP = 1 << 20
PROTO = 3
VERSION = "1.2.0"

# Log tailing. opencode.log routinely sits at tens of megabytes and is full of
# walls from past sessions; the guard must only ever act on lines written after
# it starts. Fresh install begins at EOF, and any gap larger than CATCHUP_MAX
# (long sleep, log rotation, guard restart) resumes near the tail instead of
# replaying history and burning registrations on old quota errors.
READ_CHUNK = 256 * 1024
CATCHUP_MAX = 1024 * 1024
TAIL_WINDOW = 128 * 1024


# ---------------------------------------------------------------- plumbing

def run(cmd, timeout=30, env=None):
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except FileNotFoundError:
        return 127, "", "not found: " + cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timeout: " + " ".join(cmd)


def ensure_dirs():
    for d in (ROOT, STATE):
        d.mkdir(parents=True, exist_ok=True)


def jload(path, default):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return default


def jsave(path, data):
    """Atomic replace with a per-process/per-thread temp name.

    A shared `<path>.tmp` is a race: two writers in the same instant, one renames
    it away, the other gets ENOENT and the request that triggered it dies. That
    is exactly what happened under a concurrent burst against a cold edge cache.
    """
    ensure_dirs()
    tmp = Path(f"{path}.{os.getpid()}.{threading.get_ident()}.tmp")
    tmp.write_text(json.dumps(data))
    try:
        os.replace(tmp, path)
    except OSError:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise


def now():
    return int(time.time())


def stamp():
    return time.strftime("%m-%d %H:%M:%S")


def log(path, line):
    ensure_dirs()
    try:
        if path.exists() and path.stat().st_size > LOG_CAP:
            keep = path.read_text(errors="replace")[-LOG_CAP // 2:]
            path.write_text("… trimmed …\n" + keep)
    except Exception:
        pass
    with open(path, "a") as fh:
        fh.write(f"{stamp()} {line}\n")


_THROTTLE: dict = {}


def log_throttled(path, key, line, every=60):
    """Same line at most once per `every` seconds. A wall that cannot be acted
    on (cooldown, hourly cap) must not paint the log every tick."""
    t = time.monotonic()
    if t - _THROTTLE.get(key, 0) >= every:
        _THROTTLE[key] = t
        log(path, line)


class FileLock:
    """Exclusive advisory lock. Used so two guards, or a guard and a manual
    `ocul hop`, can never drive warp-cli at the same time — that is how a
    registration ends up deleted twice and the tunnel lands in a half state."""

    def __init__(self, path):
        self.path = Path(path)
        self.fh = None

    def acquire(self):
        ensure_dirs()
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.fh = open(self.path, "a+")
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if self.fh:
                self.fh.close()
                self.fh = None
            return False
        self.fh.seek(0)
        self.fh.truncate()
        self.fh.write(f"{os.getpid()} {stamp()}\n")
        self.fh.flush()
        return True

    def release(self):
        if not self.fh:
            return
        try:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        except Exception:
            pass
        self.fh.close()
        self.fh = None


ROTATE_LOCK = STATE / "rotate.lock"
GUARD_LOCK = STATE / "guard.lock"


class RotationBusy(RuntimeError):
    """Another process already owns ROTATE_LOCK. Not an error to alarm on."""


def save_if_changed(path, data):
    if jload(path, None) != data:
        jsave(path, data)


def notify(title, body):
    script = (
        'display notification %s with title %s'
        % (json.dumps(body), json.dumps(title))
    )
    run(["osascript", "-e", script], timeout=5)


# ---------------------------------------------------------------- warp

def warp_text():
    rc, out, err = run([WARP, "status"], timeout=8)
    return (out or err or "").splitlines()[0] if (out or err) else ""


def warp_connected():
    return "connected" in warp_text().lower() and "disconnected" not in warp_text().lower()


_IFACE = {"addr": None, "ts": 0.0}


def iface_v6(force=False):
    """The WARP-owned source address. This is what gets bound, per connection.

    Cached for a couple of seconds: the proxy asks per request, and spawning
    `ifconfig` for every connection was the single slowest thing it did. Rotation
    invalidates the cache explicitly.
    """
    t = time.monotonic()
    if not force and _IFACE["addr"] is not None and t - _IFACE["ts"] < IFACE_CACHE_TTL:
        return _IFACE["addr"]
    rc, out, _ = run(["ifconfig"], timeout=8)
    addr = None
    cur = None
    for line in out.splitlines():
        if line and not line[0].isspace():
            cur = line.split(":")[0]
            continue
        if cur and cur.startswith("utun") and "inet6 2606:4700" in line:
            addr = line.split()[1].split("%")[0]
            break
    _IFACE["addr"] = addr
    _IFACE["ts"] = t
    return addr


def registered():
    rc, out, _ = run([WARP, "registration", "show"], timeout=8)
    return rc == 0 and "ID:" in out


def route_iface(addr):
    rc, out, _ = run(["route", "-n", "get", "-inet6", addr], timeout=8)
    for line in out.splitlines():
        if "interface:" in line:
            return line.split(":", 1)[1].strip()
    return None


_DNS: dict = {}


def aaaa(host, force=False):
    """Real AAAA records.

    WARP's resolver hands back v4-mapped answers (::ffff:a.b.c.d) for AAAA
    queries on this host, and socket.AF_INET6 then refuses to connect to them.
    Ask the resolver directly and keep only genuine v6 literals. Answers are
    cached so a burst of requests costs one `dig`, not one per connection.
    """
    t = time.monotonic()
    hit = _DNS.get(host)
    if hit and not force and t - hit[1] < DNS_CACHE_TTL:
        return list(hit[0])

    found = set()
    for server in ("@1.1.1.1", None):
        cmd = ["dig", "+short", "+time=3", "+tries=1", "AAAA", host]
        if server:
            cmd.append(server)
        rc, out, _ = run(cmd, timeout=8)
        for line in out.splitlines():
            addr = line.strip()
            if addr.count(":") >= 3 and not addr.startswith("::ffff:") and ";" not in addr:
                found.add(addr)
        if found:
            break
    if not found:
        try:
            infos = socket.getaddrinfo(host, 443, socket.AF_INET6, socket.SOCK_STREAM)
            found = {
                i[4][0].split("%")[0]
                for i in infos
                if not i[4][0].startswith("::ffff:")
            }
        except OSError:
            pass
    out_list = sorted(found)
    _DNS[host] = (out_list, t)
    return out_list


_TLS_CTX = None
_TLS_LOCK = threading.Lock()


def tls_ctx():
    """One context, built once. Four probe threads racing create_default_context()
    on a cold cache is a real (if rare) failure path, and the lock costs nothing
    after the first call."""
    global _TLS_CTX
    if _TLS_CTX is not None:
        return _TLS_CTX
    with _TLS_LOCK:
        if _TLS_CTX is None:
            _TLS_CTX = ssl.create_default_context()
    return _TLS_CTX


def probe(edge, src, timeout=PROBE_TIMEOUT):
    """TLS handshake, not just a TCP open: a pinned edge that cannot complete
    a handshake is not a usable edge."""
    try:
        raw = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        raw.settimeout(timeout)
        raw.bind((src, 0))
        raw.connect((edge, 443))
        tls = tls_ctx().wrap_socket(raw, server_hostname="opencode.ai")
        tls.close()
        return True
    except (OSError, ssl.SSLError):
        return False


def edge_pool(host, src, exclude=()):
    edges = [e for e in aaaa(host) if e not in exclude]
    random.shuffle(edges)
    if not edges:
        return []
    with ThreadPoolExecutor(max_workers=min(PROBE_PARALLEL, len(edges))) as pool:
        verdicts = list(pool.map(lambda e: probe(e, src), edges))
    good = [e for e, ok in zip(edges, verdicts) if ok]
    return good or edges


_EDGE_LOCK = threading.Lock()


def current_edge(host, src):
    """Validated edge for this launch, cached briefly so a burst of requests
    does not re-probe for every connection.

    The cache is keyed on (host, source address): after a rotation the old edge
    is still anycast-reachable, but re-validating against the new source is what
    makes the next request prove the tunnel actually works.

    The probe runs under a lock: on a cold cache forty concurrent requests would
    otherwise each fire four TLS handshakes at the same two edges. One probes,
    the rest read what it wrote.
    """
    st = jload(EDGE_STATE, {})
    fresh = (
        st.get("host") == host
        and st.get("src") == src
        and now() - st.get("ts", 0) < EDGE_CACHE_TTL
    )
    if fresh and st.get("edge") and st.get("ts", 0) > st.get("reroll_seen", 0):
        return st["edge"]

    with _EDGE_LOCK:
        st = jload(EDGE_STATE, {})
        fresh = (
            st.get("host") == host
            and st.get("src") == src
            and now() - st.get("ts", 0) < EDGE_CACHE_TTL
        )
        if fresh and st.get("edge") and st.get("ts", 0) > st.get("reroll_seen", 0):
            return st["edge"]
        pool = edge_pool(host, src, exclude={st.get("edge")} if st.get("edge") else set())
        if not pool:
            return None
        edge = random.choice(pool)
        jsave(EDGE_STATE, {
            "host": host, "edge": edge, "src": src, "ts": now(),
            "reroll_seen": st.get("reroll", 0), "reroll": st.get("reroll", 0),
        })
        return edge


def reroll():
    st = jload(EDGE_STATE, {})
    st["reroll"] = st.get("reroll", 0) + 1
    st["ts"] = 0
    jsave(EDGE_STATE, st)


def drop_caches():
    """Called after a rotation: the source address, its DNS answers and the
    pinned edge all refer to the previous registration."""
    _IFACE["addr"] = None
    _IFACE["ts"] = 0.0
    _DNS.clear()
    reroll()


def prefix64(addr):
    if not addr or ":" not in addr:
        return None
    parts = addr.split(":")[:4]
    return ":".join(parts)


def trace_v6(src, edge=None):
    """What the server sees, measured on the same path the lane uses."""
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.settimeout(CONNECT_TIMEOUT)
        s.bind((src, 0))
        target = edge or random.choice(aaaa(TRACE_HOST) or ["2606:4700::6810:84e5"])
        s.connect((target, 443))
        tls = ssl.create_default_context().wrap_socket(s, server_hostname=TRACE_HOST)
        tls.sendall(
            f"GET {TRACE_PATH} HTTP/1.1\r\nHost: {TRACE_HOST}\r\n"
            "User-Agent: ocul\r\nConnection: close\r\n\r\n".encode()
        )
        raw = b""
        while len(raw) < 65536:
            chunk = tls.recv(4096)
            if not chunk:
                break
            raw += chunk
        tls.close()
        body = raw.split(b"\r\n\r\n", 1)[-1].decode("latin1")
        fields = dict(
            line.split("=", 1) for line in body.splitlines() if "=" in line
        )
        return fields
    except (OSError, ssl.SSLError):
        return {}


# ---- daemon health, GUI parking, one global lock ---------------------------

WARP_APP = "/Applications/Cloudflare WARP.app"
DAEMON_LABEL = "com.cloudflare.1dot1dot1dot1.macos.warp.daemon"

# ONE lock every rotator on this Mac shares, regardless of stack. ouc's python
# guard/keeper, a stray zen-hop and ocul all touch warp-cli; without a common
# token they delete the same registration twice and the tunnel lands down.
GLOBAL_ROTATE_LOCK = Path(os.environ.get(
    "OCUL_GLOBAL_LOCK",
    HOME / "Library/Application Support/opencode-unlimited/rotate.global.lock"))

_DAEMON_DEAD = (
    "unable to connect to the cloudflarewarp daemon",
    "maybe the daemon is not running",
    "no such file or directory",
    "connection refused",
    "os error 2",
)
_API_BUSY = (
    "failed to communicate with the warp api",
    "too many requests",
    "rate limit",
    "try again later",
)


def _low(text):
    return (text or "").lower()


def daemon_down(text):
    t = _low(text)
    return any(s in t for s in _DAEMON_DEAD)


def api_busy(text):
    t = _low(text)
    return any(s in t for s in _API_BUSY)


def daemon_alive():
    rc, out, err = run([WARP, "status"], timeout=12)
    if daemon_down(err) or daemon_down(out):
        return False
    return rc == 0 or "status update" in _low(out + err)


def ensure_daemon():
    """The WARP.app daemon is a root LaunchDaemon. When the front-end is
    updating, or was quit while the registration was deleted, its socket file
    vanishes and every warp-cli call dies with 'No such file or directory'.
    Relaunch the app so launchd resurrects the daemon, then wait for the socket.
    """
    if daemon_alive():
        return True
    log(GUARD_LOG, "warp daemon unreachable — relaunching the front-end")
    run(["open", "-g", "-a", WARP_APP], timeout=15)
    deadline = time.time() + 45
    while time.time() < deadline:
        time.sleep(2)
        if daemon_alive():
            log(GUARD_LOG, "warp daemon back up")
            return True
    return False


def _gui_running():
    rc, _, _ = run(
        ["pgrep", "-f", f"{WARP_APP}/Contents/MacOS/Cloudflare WARP"], timeout=8
    )
    return rc == 0


def pause_gui():
    """Quit the WARP window before the registration is deleted.

    The GUI is a separate front-end from the root daemon. If it is open when
    the registration disappears it paints the Zero Trust 'Enroll your device'
    page — the 'Something went wrong. Please try again later.' screen — and
    keeps it after the tunnel is healthy again. Park it for the surgery.
    """
    if not _gui_running():
        return False
    run(["osascript", "-e", 'tell application "Cloudflare WARP" to quit'], timeout=10)
    time.sleep(1)
    run(["pkill", "-f", f"{WARP_APP}/Contents/MacOS/Cloudflare WARP"], timeout=8)
    return True


def resume_gui(was_up):
    if was_up:
        time.sleep(1)
        run(["open", "-g", "-a", WARP_APP], timeout=15)


GUI_HOLD = STATE / "gui-hold"


def hold_gui_down():
    """WARP is a login item, so launchd resurrects the window seconds after it
    is killed. One quit is not enough: the fresh window lands while the
    registration is deleted, calls IpcStatus.missingRegistration() and paints
    the enrollment page with 'Something went wrong. Please try again later.'
    — which is exactly the screen this whole fix exists to prevent.

    Keep a background watchdog killing it for the duration of the surgery, then
    relaunch once, after the tunnel is healthy again.
    """
    pat = f"{WARP_APP}/Contents/MacOS/Cloudflare WARP"
    try:
        STATE.mkdir(parents=True, exist_ok=True)
        GUI_HOLD.write_text(str(os.getpid()))
    except OSError:
        return None
    cmd = (f'while [ -f "{GUI_HOLD}" ]; do '
           f'pkill -f "{pat}" >/dev/null 2>&1; sleep 0.4; done')
    try:
        return subprocess.Popen(
            ["/bin/bash", "-c", cmd],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
    except OSError:
        return None


def release_gui_hold(proc, was_up):
    try:
        GUI_HOLD.unlink()
    except OSError:
        pass
    if proc is not None:
        try:
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass
    resume_gui(was_up)


def rotate(verbose=True, lock_timeout=15):
    """Burn the registration, take a new one, confirm the egress /64 moved.

    Serialised on three levels, in fixed order:
      1. GLOBAL_ROTATE_LOCK — the flock every rotator on this Mac shares.
      2. ROTATE_LOCK — ocul's own.
      3. OVERLAY_GUARD/rotate.lock — the mkdir the shell stack (zen-hop) takes.

    The WARP GUI is parked and the daemon proven alive before warp-cli is
    touched. Registration attempts back off on API errors instead of hammering,
    and a rotation is only accepted when the egress /64 is both different from
    the block we left AND not already on the burned blacklist.
    """
    glock = FileLock(GLOBAL_ROTATE_LOCK)
    if not glock.acquire():
        raise RotationBusy("another rotator holds the global lock")
    lock = FileLock(ROTATE_LOCK)
    if not lock.acquire():
        glock.release()
        raise RotationBusy("rotation already in progress (another guard or hop)")

    try:
        foreign = acquire_foreign_rotlock()
    except Exception:
        lock.release()
        glock.release()
        raise

    paused = pause_keeper()
    try:
        GUI_HOLD.unlink()
    except OSError:
        pass
    gui_was_up = pause_gui()
    gui_hold = hold_gui_down()
    try:
        if not ensure_daemon():
            raise RuntimeError("warp daemon is not running")

        before_addr = iface_v6(force=True)
        before_pfx = prefix64(before_addr)
        say = print if verbose else (lambda *a, **k: None)
        say(f"old {before_pfx or '(none)'}  device {registration_id()[:8]}…")

        def drop_registration():
            last = ""
            for cmd in ([WARP, "--accept-tos", "registration", "delete"],
                        ["sudo", "-n", WARP, "--accept-tos", "registration", "delete"]):
                rc, _, err = run(cmd, timeout=42)
                last = err
                if rc == 0:
                    return True, ""
            return False, last

        def new_registration():
            last = ""
            for cmd in ([WARP, "--accept-tos", "registration", "new"],
                        ["sudo", "-n", WARP, "--accept-tos", "registration", "new"]):
                rc, out, err = run(cmd, timeout=60)
                last = out + err
                if rc == 0:
                    return True, last
            return False, last

        st = jload(GUARD_STATE, {})
        burned = set((jload(OVERLAY_STATE, {}) or {}).get("blacklist") or [])
        old_bucket = st.get("egress_prefix") or before_pfx
        if old_bucket:
            burned.add(old_bucket)

        accepted, last_err = None, ""
        attempts = 14          # per wall turn; across turns there is no limit
        burned_hits = 0
        started = time.time()
        for attempt in range(1, attempts + 1):
            if time.time() - started > 600:
                last_err = last_err or "rotation ran past its time budget"
                break
            say(f"-- rotation attempt {attempt}/{attempts} --")
            run([WARP, "--accept-tos", "disconnect"], timeout=20)
            time.sleep(1)

            ok, msg = drop_registration()
            if not ok and daemon_down(msg) and not ensure_daemon():
                last_err = msg or "daemon down"
                time.sleep(3)
                continue

            ok, msg = new_registration()
            if not ok:
                last_err = msg
                if daemon_down(msg):
                    ensure_daemon()
                if api_busy(msg):
                    # cloudflare is throttling registrations; hammering turns a
                    # 30 s blip into a 40 min outage and leaks the home IP
                    wait = min(45, 5 * (2 ** (attempt - 1)))
                    log(GUARD_LOG, f"warp api busy — backing off {wait}s")
                    time.sleep(wait)
                else:
                    time.sleep(min(12, attempt * 2))
                continue

            run([WARP, "--accept-tos", "connect"], timeout=30)
            deadline = time.time() + 45
            while time.time() < deadline:
                if warp_connected() and iface_v6(force=True):
                    break
                time.sleep(2)

            after_addr = iface_v6(force=True)
            after_pfx = prefix64(after_addr)
            # The quota key is the *egress* /64 the server sees (2a09:bac…),
            # not the utun leg (2606:4700:110:…). Measure it or the check lies.
            fields = trace_v6(after_addr) if after_addr else {}
            egress = fields.get("ip") if ":" in fields.get("ip", "") else None
            egress_pfx = prefix64(egress) if egress else None
            key = egress_pfx or after_pfx
            say(f"   -> bucket {key or '?'}  (old {old_bucket or '?'})")

            if not key:
                last_err = "no cloudflare egress after rotation"
                time.sleep(3)
                continue
            if key == old_bucket:
                last_err = f"same bucket ({key})"
                say("   same /64 handed back — rotating again")
                continue
            if key in burned:
                burned_hits += 1
                last_err = f"landed on a burned bucket ({key})"
                say("   burned /64 — a wall already hit; rotating again")
                if burned_hits >= 4:
                    # every block the live pool hands back is already burned.
                    # Buckets reset roughly daily, so the OLDEST entries are the
                    # most likely to be fresh again — recycle them rather than
                    # wedging forever. The block we just left stays burned.
                    ov = jload(OVERLAY_STATE, {}) or {}
                    bl = [x for x in (ov.get("blacklist") or []) if x]
                    if len(bl) > 8:
                        keep = bl[-(len(bl) // 2):]
                        ov["blacklist"] = keep
                        save_if_changed(OVERLAY_STATE, ov)
                        burned = set(keep)
                        if old_bucket:
                            burned.add(old_bucket)
                        burned_hits = 0
                        log(GUARD_LOG, f"recycled blacklist to {len(keep)} newest blocks")
                        say(f"   pool saturated — recycled burn list to {len(keep)} blocks")
                time.sleep(min(WALL_BACKOFF_MAX, 2 * attempt))
                continue

            accepted = (key, after_addr, after_pfx, egress, registration_id())
            break

        if not accepted:
            st["collisions"] = st.get("collisions", 0) + 1
            st["last_hop"] = now()
            jsave(GUARD_STATE, st)
            raise RuntimeError(last_err or "no fresh /64 after retries")

        key, after_addr, after_pfx, egress, did = accepted
        _OVERLAY_DEV.update(id=did, ts=time.time())
        st.update({"last_hop": now(), "hops": st.get("hops", 0) + 1,
                   "prefix": after_pfx, "addr": after_addr,
                   "egress": egress, "egress_prefix": key, "collisions": 0})
        jsave(GUARD_STATE, st)
        drop_caches()
        record_wall("rotated", f"egress {key} (device {before_pfx} -> {after_pfx})")
        overlay_rotate(old_bucket, key, did)
        publish_overlay_state("rotate")
        say(f"new {after_pfx or '(none)'}  egress {key}  device {did[:8]}…")
        return True, before_pfx, after_pfx
    finally:
        release_gui_hold(gui_hold, gui_was_up)
        if paused:
            resume_keeper()
        if foreign:
            release_foreign_rotlock()
        lock.release()
        glock.release()


def registration_id():
    rc, out, _ = run([WARP, "registration", "show"], timeout=8)
    for line in out.splitlines():
        if line.startswith("ID:"):
            return line.split(":", 1)[1].strip()
    return "????????"


def record_wall(what, extra=""):
    st = jload(GUARD_STATE, {})
    entry = {"ts": now(), "what": what, "extra": extra,
             "egress": st.get("egress_prefix"),
             "prefix": st.get("prefix")}
    ensure_dirs()
    try:
        if WALLS.exists() and WALLS.stat().st_size > WALLS_CAP:
            keep = WALLS.read_text(errors="replace").splitlines()[-500:]
            WALLS.write_text("\n".join(keep) + "\n")
    except Exception:
        pass
    with open(WALLS, "a") as fh:
        fh.write(json.dumps(entry) + "\n")


# ---------------------------------------------------------------- proxy

class FailClosed(Exception):
    pass


def allow_host(host):
    host = host.lower().strip("[]")
    return host in PIN_HOSTS or any(host.endswith("." + h) for h in PIN_HOSTS)


async def read_head(reader, cap=65536):
    buf = b""
    while b"\r\n\r\n" not in buf:
        try:
            chunk = await asyncio.wait_for(reader.read(4096), HEAD_TIMEOUT)
        except asyncio.TimeoutError:
            raise FailClosed("client never sent a request head")
        if not chunk:
            return buf
        buf += chunk
        if len(buf) > cap:
            raise FailClosed("request head too large")
    return buf


def target_of(head: bytes):
    line = head.split(b"\r\n", 1)[0].decode("latin1")
    parts = line.split()
    if len(parts) < 2:
        raise FailClosed("bad request line")
    method, target = parts[0], parts[1]
    if method == "CONNECT":
        host, _, port = target.rpartition(":")
        return method, host.strip("[]"), int(port or 443)
    m = re.match(r"https?://([^/:]+)(?::(\d+))?", target)
    if not m:
        raise FailClosed("unsupported target form")
    return method, m.group(1), int(m.group(2) or 80)


async def _dial(dest, src):
    loop = asyncio.get_running_loop()
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.setblocking(False)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        sock.bind((src, 0))
    except OSError as exc:
        sock.close()
        raise FailClosed(f"cannot bind WARP address {src}: {exc}") from exc
    try:
        await asyncio.wait_for(loop.sock_connect(sock, dest), CONNECT_TIMEOUT)
    except (OSError, asyncio.TimeoutError) as exc:
        sock.close()
        raise FailClosed(f"connect {dest[0]} failed: {exc}") from exc
    return sock


async def dial_any(dests, src):
    """Try every candidate over the same bound source.

    A dual-stack host can publish an AAAA that its own edge does not serve over
    IPv6 (seen on several canary domains); one bad address must not kill the
    request when another address on the same host works.
    """
    last = None
    for dest in dests:
        try:
            sock = await _dial(dest, src)
            return sock, dest[0]
        except FailClosed as exc:
            last = exc
    raise FailClosed(f"every IPv6 candidate failed ({last})") from last


async def connect_pinned(host, port, src):
    loop = asyncio.get_running_loop()
    if not allow_host(host):
        # Non-quota traffic: ride the tunnel when the host has a usable AAAA,
        # otherwise take the ordinary route. Only the pinned set carries the
        # quota identity, so only the pinned set is worth refusing over.
        addrs = aaaa(host)
        if addrs:
            random.shuffle(addrs)
            try:
                sock, used = await dial_any([(a, port, 0, 0) for a in addrs], src)
                return (await asyncio.open_connection(sock=sock)) + (used,)
            except FailClosed:
                pass
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(host, port), CONNECT_TIMEOUT
            )
            return reader, writer, host
        except (OSError, asyncio.TimeoutError) as exc:
            raise FailClosed(f"unreachable {host}:{port}: {exc!r}") from exc

    edge = await loop.run_in_executor(None, current_edge, host, src)
    if not edge:
        raise FailClosed(f"no live edge for {host}")
    try:
        sock = await _dial((edge, port, 0, 0), src)
        return (await asyncio.open_connection(sock=sock)) + (edge,)
    except FailClosed:
        # the pinned edge went dark between pump and connect: reroll the pool
        # and spend one more candidate before giving up on this request
        reroll()
        pool = await loop.run_in_executor(None, edge_pool, host, src, {edge})
        if not pool:
            raise FailClosed(f"no live edge for {host}")
        sock, used = await dial_any([(e, port, 0, 0) for e in pool[:3]], src)
        return (await asyncio.open_connection(sock=sock)) + (used,)


async def relay(reader, writer):
    """One direction of a tunnel.

    On EOF the far side gets write_eof(), not close(): a client that half-closes
    after sending its request must still receive the response, and an SSE stream
    must be able to finish after the upload is done. The read timeout keeps
    abandoned connections from holding fds until the process dies.
    """
    try:
        while True:
            data = await asyncio.wait_for(reader.read(65536), IDLE_TIMEOUT)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (asyncio.TimeoutError, OSError, asyncio.IncompleteReadError):
        pass
    except asyncio.CancelledError:
        raise
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except Exception:
            pass


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")
    host, port, established, counted = "?", 0, False, False
    uwriter = None
    try:
        try:
            head = await read_head(reader)
        except FailClosed as exc:
            STATS["refused"] += 1
            counted = True
            log(PROXY_LOG, f"REFUSED {peer}: {exc}")
            await deny(writer, 400, f"ocul: {exc}")
            return
        if not head:
            return
        # health is the lane's liveness probe: it must not be counted as traffic,
        # or a keepalive loop makes the counters look like real load
        if b"/__ocul/health" in head.split(b"\r\n", 1)[0]:
            return await health_report(writer)

        STATS["active"] += 1
        STATS["total"] += 1
        counted = True

        method, host, port = target_of(head)
        src = iface_v6()
        if not src:
            raise FailClosed("WARP has no IPv6 address (fail-closed)")

        ureader, uwriter, used = await connect_pinned(host, port, src)

        if method == "CONNECT":
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            established = True
            await asyncio.gather(relay(reader, uwriter), relay(ureader, writer))
        else:
            established = True
            uwriter.write(head)
            await uwriter.drain()
            await asyncio.gather(relay(reader, uwriter), relay(ureader, writer))

        log(PROXY_LOG, f"{method} {host}:{port} via {used} src {src}")
    except FailClosed as exc:
        STATS["refused"] += 1
        log(PROXY_LOG, f"REFUSED {peer}: {exc}")
        await deny(writer, 403, f"ocul: {exc}")
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        STATS["errors"] += 1
        tb = traceback.format_exc().strip().splitlines()[-1]
        log(PROXY_LOG, f"ERR {host}:{port} {peer}: {exc!r} @ {tb}")
        # a request that never got its 200 deserves an answer, not a dropped
        # socket — the client needs to know the tunnel failed on our side
        if not established:
            await deny(writer, 502, f"ocul: upstream {host}:{port} failed: {exc}")
    finally:
        if counted:
            STATS["active"] = max(0, STATS["active"] - 1)
        # Both ends get closed explicitly. Closing only the client side leaves the
        # upstream transport alive in CLOSED state until CPython gets around to
        # collecting it — that is a file descriptor per request, and a proxy that
        # runs for days dies of EMFILE instead of doing its job.
        for w in (writer, uwriter):
            if w is None:
                continue
            try:
                w.close()
            except Exception:
                pass


async def deny(writer, code, message):
    reasons = {400: "Bad Request", 403: "Forbidden", 502: "Bad Gateway",
               503: "Service Unavailable"}
    body = (message + "\n").encode()
    try:
        writer.write(
            f"HTTP/1.1 {code} {reasons.get(code, 'Error')}\r\n".encode()
            + b"Content-Type: text/plain\r\n"
            + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            + body
        )
        await writer.drain()
    except Exception:
        pass


async def health_report(writer):
    payload = {
        "proto": PROTO,
        "version": VERSION,
        "pid": os.getpid(),
        "uptime": int(time.time() - STATS["started"]),
        "active": STATS["active"],
        "total": STATS["total"],
        "errors": STATS["errors"],
        "refused": STATS["refused"],
        "src": iface_v6(),
        "edge": jload(EDGE_STATE, {}).get("edge"),
        "max_conns": MAX_CONNS,
    }
    body = json.dumps(payload).encode()
    try:
        writer.write(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
            + body
        )
        await writer.drain()
    except Exception:
        pass


STATS = {"started": time.time(), "active": 0, "total": 0, "errors": 0, "refused": 0}
_SEM = None


async def proxy_serve(port):
    global _SEM
    ensure_dirs()
    PROXY_PID.write_text(str(os.getpid()))
    _SEM = asyncio.Semaphore(MAX_CONNS)
    STATS["started"] = time.time()

    async def limited(reader, writer):
        # ceiling check before the semaphore so an overloaded proxy answers 503
        # immediately instead of queueing the client behind 512 slow tunnels
        if STATS["active"] >= MAX_CONNS:
            await deny(writer, 503, "ocul: connection ceiling reached")
            return
        async with _SEM:
            await handle(reader, writer)

    server = await asyncio.start_server(limited, "127.0.0.1", port, backlog=512)
    src = iface_v6(force=True)
    log(PROXY_LOG, f"proxy up on 127.0.0.1:{port} proto={PROTO} src {src}")

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop.set)
        except NotImplementedError:
            pass

    await stop.wait()
    server.close()
    await server.wait_closed()

    pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)

    if PROXY_PID.exists():
        try:
            if PROXY_PID.read_text().strip() == str(os.getpid()):
                PROXY_PID.unlink()
        except Exception:
            pass
    log(PROXY_LOG, "proxy stopped (clean)")


def port_open(port, host="127.0.0.1"):
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def proxy_health(port, timeout=2.0):
    """Talk to our own health route. This is how the lane distinguishes a live
    ocul proxy from a stale build or an unrelated listener on the port — the
    exact confusion that let an old process serve a patched tree earlier."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as s:
            s.sendall(
                b"GET http://127.0.0.1:%d/__ocul/health HTTP/1.1\r\n"
                b"Host: 127.0.0.1\r\nConnection: close\r\n\r\n" % port
            )
            raw = b""
            while len(raw) < 65536:
                chunk = s.recv(4096)
                if not chunk:
                    break
                raw += chunk
        body = raw.split(b"\r\n\r\n", 1)[-1]
        return json.loads(body.decode())
    except Exception:
        return None


def kill_proxy(port):
    h = proxy_health(port) or {}
    pid = h.get("pid")
    if not pid:
        rc, out, _ = run(["lsof", "-nP", "-tiTCP:%d" % port, "-sTCP:LISTEN"], timeout=5)
        pid = int(out.split()[0]) if out.strip() else None
    if not pid:
        return not port_open(port)
    try:
        os.kill(int(pid), signal.SIGTERM)
    except OSError:
        pass
    for _ in range(50):
        if not port_open(port):
            return True
        time.sleep(0.1)
    try:
        os.kill(int(pid), signal.SIGKILL)
    except OSError:
        pass
    return not port_open(port)


def ensure_proxy(port):
    h = proxy_health(port)
    if h and h.get("proto") == PROTO:
        return True
    if h or port_open(port):
        log(PROXY_LOG, f"stale proxy on {port} (proto {(h or {}).get('proto')}) — replacing")
        kill_proxy(port)

    ensure_dirs()
    log(PROXY_LOG, f"starting proxy on {port} proto={PROTO}")
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "proxy", "--port", str(port)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    for _ in range(60):
        h = proxy_health(port, timeout=0.6)
        if h and h.get("proto") == PROTO:
            return True
        time.sleep(0.25)
    return False


# ---------------------------------------------------------------- commands

def find_opencode():
    skip = ("zen-lane", "ocul", "scripts/lane.sh")
    cands = [
        HOME / ".opencode/bin/opencode",
        HOME / ".npm-global/bin/opencode",
        Path("/opt/homebrew/bin/opencode"),
        Path("/usr/local/bin/opencode"),
    ]
    mine = HOME / ".local/bin/opencode"
    for c in cands:
        if c.exists() and os.access(c, os.X_OK):
            try:
                head = c.read_text(errors="ignore")[:2000]
            except Exception:
                head = ""
            if any(s in head for s in skip):
                continue
            return str(c)
    if mine.exists():
        return str(mine)
    return shutil.which("opencode")


def split_lane_args(args):
    """Peel ocul's own flags off the front, hand the rest to opencode verbatim.

    argparse cannot do this: a REMAINDER subparser reorders tokens when the
    child binary takes single-dash flags (-c, -m, --print …), which silently
    corrupts the command line. Manual split, first unknown token ends the peel.
    """
    port = int(os.environ.get("OCUL_PORT", 40123))
    fresh = True
    rest = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--port" and i + 1 < len(args):
            port = int(args[i + 1])
            i += 2
        elif a.startswith("--port="):
            port = int(a.split("=", 1)[1])
            i += 1
        elif a == "--fresh-id":
            fresh = True
            i += 1
        elif a == "--no-fresh-id":
            fresh = False
            i += 1
        elif a == "--":
            rest.extend(args[i + 1:])
            break
        else:
            rest.extend(args[i:])
            break
    return port, fresh, rest


def sweep_stale_shims():
    """Remove per-launch shim dirs whose process is gone.

    A hard kill (timeout, closed terminal) skips the `finally` that removes the
    dir, and state would slowly fill with dead `bin.<pid>` trees.
    """
    for d in STATE.glob("bin.*"):
        try:
            pid = int(d.name.split(".", 1)[1])
        except (IndexError, ValueError):
            continue
        alive = True
        try:
            os.kill(pid, 0)
        except OSError:
            alive = False
        if not alive:
            shutil.rmtree(d, ignore_errors=True)


def cmd_lane(args):
    port, fresh_id, rest = split_lane_args(args)
    known = argparse.Namespace(port=port, fresh_id=fresh_id)
    rest = rest
    sweep_stale_shims()

    # The CLI does not make model requests itself: it talks to a background
    # opencode server (`opencode service`, usually a third-party shell's child)
    # and that server owns the outbound socket. A server started outside the lane
    # has no proxy env, so the traffic leaves direct and the whole mechanism is
    # decorative. `--standalone` makes the CLI run a private server as its child,
    # which inherits this environment. Explicit --server/--standalone wins.
    forced_standalone = False
    if not os.environ.get("OCUL_NO_STANDALONE"):
        if not any(a == "--standalone" or a.startswith("--server") for a in rest):
            rest = ["--standalone"] + rest
            forced_standalone = True

    src = iface_v6()
    if not warp_connected() or not src:
        log(LANE_LOG, "warp down at launch — attempting one repair")
        try:
            run([WARP, "--accept-tos", "connect"], timeout=20)
            for _ in range(15):
                src = iface_v6()
                if warp_connected() and src:
                    break
                time.sleep(2)
        except Exception:
            pass
    if not warp_connected() or not src:
        print("ocul: WARP IPv6 tunnel is not up — refusing to launch (fail-closed).", file=sys.stderr)
        print("      run: ocul hop    or    warp-cli connect", file=sys.stderr)
        return 3

    if not ensure_proxy(known.port):
        print(f"ocul: proxy did not come up on 127.0.0.1:{known.port}", file=sys.stderr)
        return 4

    real = os.environ.get("OCUL_REAL_BIN") or find_opencode()
    if not real:
        print("ocul: opencode binary not found (set OCUL_REAL_BIN)", file=sys.stderr)
        return 5

    env = dict(os.environ)
    proxy = f"http://127.0.0.1:{known.port}"
    for key in ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"):
        env[key] = proxy
    env["NO_PROXY"] = env["no_proxy"] = "localhost,127.0.0.1,::1"

    tmpdir = None
    if known.fresh_id:
        import uuid
        tmpdir = STATE / f"bin.{os.getpid()}"
        shutil.rmtree(tmpdir, ignore_errors=True)
        tmpdir.mkdir(parents=True, exist_ok=True)
        fake = str(uuid.uuid4()).upper()
        shim = tmpdir / "ioreg"
        shim.write_text(
            "#!/bin/bash\n"
            'case "$*" in *IOPlatformExpertDevice*)\n'
            "printf '%s\\n' '+-o IOPlatformExpertDevice  <class IOPlatformExpertDevice, id 0x100000100>'\n"
            f"printf '%s\\n' '    \"IOPlatformUUID\" = \"{fake}\"'\n"
            "exit 0;; esac\n"
            'exec /usr/sbin/ioreg "$@"\n'
        )
        shim.chmod(0o755)
        env["PATH"] = f"{tmpdir}:{env.get('PATH', '')}"
        env["OCUL_MACHINE_ID"] = fake

    edge = jload(EDGE_STATE, {}).get("edge")
    log(LANE_LOG,
        f"launch edge {edge} src {src} proxy {proxy} bin {real} "
        f"standalone={forced_standalone} argv={' '.join(rest[:6]) or '(tui)'}")
    try:
        proc = subprocess.run([real] + rest, env=env)
        return proc.returncode
    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)


def cmd_proxy(args):
    asyncio.run(proxy_serve(args.port))


# ---------------------------------------------------------------- overlay

_OVERLAY_DEV = {"id": "", "ts": 0.0}


def overlay_device():
    """The HUD's device tile: registration id, cached two minutes.

    warp-cli is a subprocess; asking it on every 6 s tick for a value that only
    changes on a rotation is 14k useless spawns a day.
    """
    if _OVERLAY_DEV["id"] and time.time() - _OVERLAY_DEV["ts"] < 120:
        return _OVERLAY_DEV["id"]
    did = registration_id()
    if did and set(did) != {"?"}:
        _OVERLAY_DEV.update(id=did, ts=time.time())
    return _OVERLAY_DEV["id"]


def publish_overlay_state(reason="tick"):
    """Write ocul's live truth into the files the HUD already reads.

    Everything comes out of local state — no probe, no DNS, no trace — because
    this runs on the guard tick. Returns the two dicts written, or None when the
    sync is off or the HUD is not installed.
    """
    if not OVERLAY_SYNC or not OVERLAY_GUARD.is_dir():
        return None

    port = int(os.environ.get("OCUL_PORT", 40123))
    health = proxy_health(port)
    live = bool(health) and health.get("proto") == PROTO
    st = jload(GUARD_STATE, {})
    egress = st.get("egress") or ""
    pfx = st.get("egress_prefix") or (prefix64(egress) if ":" in egress else "")
    edge = jload(EDGE_STATE, {}).get("edge") or ""
    device = overlay_device() or ""

    px = jload(OVERLAY_PROXY_STATE, {}) or {}
    px.pop("uptime", None)          # legacy key from the old mux
    px.pop("reason", None)          # debug noise; the log has it
    before = {k: v for k, v in px.items() if k != "ts"}
    px.update({
        "up": live,
        "pid": int(health.get("pid") or 0) if live else 0,
        "listen": f"127.0.0.1:{port}",
        "policy": "strict",
        "pool": 1 if live else 0,
        "healthy": 1 if live else 0,
        "tested": 1 if live else 0,
        "index": 0,
        "current": f"{edge} -> {pfx or 'no egress'}" if live else None,
        "rotations": int(st.get("hops") or 0),
        "served": int(health.get("total") or 0) if live else 0,
        "failed": (int(health.get("errors") or 0) + int(health.get("refused") or 0))
                  if live else 0,
        "system": False,
        "by": "ocul",
        "ts": now(),
    })
    after = {k: v for k, v in px.items() if k != "ts"}
    # a tick that changes nothing must not rewrite the file just to bump a clock
    if before != after:
        jsave(OVERLAY_PROXY_STATE, px)

    ov = jload(OVERLAY_STATE, {}) or {}
    ov_before = {k: v for k, v in ov.items() if k != "ocul_ts"}
    ov["prefix"] = pfx or ov.get("prefix", "")
    ov["seen6"] = egress or ov.get("seen6", "")
    ov["egress"] = egress or ov.get("egress", "")
    if device:
        ov["device"] = device
    # their counter is the machine's rotation history; ocul's starts at zero on
    # install, so the max keeps the tile monotonic without double-counting
    ov["hops"] = max(int(ov.get("hops") or 0), int(st.get("hops") or 0))
    ov["collisions"] = max(int(ov.get("collisions") or 0), int(st.get("collisions") or 0))
    ov["ocul_ts"] = now()
    ov_after = {k: v for k, v in ov.items() if k != "ocul_ts"}
    if ov_before != ov_after:
        jsave(OVERLAY_STATE, ov)
    return {"proxy": px, "state": ov}


def overlay_credit(pfx, kind, device=""):
    """Keep the per-bucket ledger honest for the /64 that was just used.

    The HUD's BUCKET line reads walls and hops for the current block out of
    guard/identities.json, and nothing else writes that file any more.
    """
    if not OVERLAY_SYNC or not pfx or not OVERLAY_LEDGER.parent.is_dir():
        return
    led = jload(OVERLAY_LEDGER, {}) or {}
    buckets = led.setdefault("buckets", {})
    e = buckets.get(pfx) or {"first": now(), "last": now(), "hops": 0,
                             "walls": 0, "device": ""}
    e["last"] = now()
    e[kind] = int(e.get(kind) or 0) + 1
    if device:
        e["device"] = device
    buckets[pfx] = e
    save_if_changed(OVERLAY_LEDGER, led)


def overlay_rotate(burned_pfx, fresh_pfx, device=""):
    """HUD bookkeeping for one real rotation: burn the old /64, credit the new,
    and move the counter the tile shows."""
    if not OVERLAY_SYNC or not OVERLAY_GUARD.is_dir():
        return
    ov = jload(OVERLAY_STATE, {}) or {}
    bl = [x for x in (ov.get("blacklist") or []) if x]
    if burned_pfx and burned_pfx not in bl:
        bl.append(burned_pfx)
    ov["blacklist"] = bl
    ov["hops"] = int(ov.get("hops") or 0) + 1
    # their guard reads last_hop as "cooldown until" (it stamps now+900 on a
    # parked rotation), so a small future stamp makes it stand down for the
    # same window instead of burning a second /64 on the wall we just cleared
    ov["last_hop"] = now() + HOP_COOLDOWN
    if device:
        ov["device"] = device
    save_if_changed(OVERLAY_STATE, ov)
    if burned_pfx:
        overlay_credit(burned_pfx, "walls")
    if fresh_pfx:
        overlay_credit(fresh_pfx, "hops", device)


def pause_keeper():
    """Tell warp-keeper.sh to stand down while a rotation owns warp-cli.

    Its repair path does clear_registration + registration new; landing that
    between our delete and our new registration leaves the tunnel registered but
    disconnected. The marker is pid-owned, so a crashed rotator cannot leave the
    keeper paused for ever.
    """
    if not OVERLAY_GUARD.is_dir():
        return False
    try:
        OVERLAY_KEEPER_PAUSE.write_text(str(os.getpid()))
        return True
    except OSError:
        return False


def resume_keeper():
    try:
        OVERLAY_KEEPER_PAUSE.unlink()
    except OSError:
        pass


def acquire_foreign_rotlock():
    """Take the third-party stack's tunnel lock as well as our own.

    zen-guard.sh and zen-hop.sh serialise rotations with a mkdir at
    guard/rotate.lock and a 300 s stale window. ocul's flock is invisible to
    them, so without this a HUD hop and a wall rotation can delete the same
    registration under each other. True when the directory is ours.
    """
    if not OVERLAY_GUARD.is_dir():
        return False
    deadline = time.time() + 15
    while True:
        try:
            OVERLAY_ROTLOCK.mkdir()
            return True
        except FileExistsError:
            try:
                age = time.time() - OVERLAY_ROTLOCK.stat().st_mtime
            except OSError:
                age = 0
            if age > 300:
                shutil.rmtree(OVERLAY_ROTLOCK, ignore_errors=True)
                continue
            if time.time() >= deadline:
                raise RotationBusy("guard/rotate.lock is held by the other rotator")
            time.sleep(2)
        except OSError:
            return False


def release_foreign_rotlock():
    shutil.rmtree(OVERLAY_ROTLOCK, ignore_errors=True)


def refresh_egress():
    """Record the /64 the server actually sees, whenever it changes.

    WARP hands back a different egress block on a plain reconnect, not only on a
    registration burn — so the quota key moves by itself sometimes. If the guard
    does not notice, `doctor` reports drift forever and `rotate()` measures
    "moved" against a stale value, which is how a real collision gets counted as
    a success.
    """
    src = iface_v6()
    if not src:
        return None
    ip = trace_v6(src).get("ip", "")
    if ":" not in ip:
        return None
    pfx = prefix64(ip)
    st = jload(GUARD_STATE, {})
    if pfx != st.get("egress_prefix"):
        prev = st.get("egress_prefix")
        st.update({"egress": ip, "egress_prefix": pfx, "egress_seen": now()})
        save_if_changed(GUARD_STATE, st)
        log(GUARD_LOG, f"egress moved {prev or '(none)'} -> {pfx} without a rotation")
        record_wall("egress-drift", f"{prev} -> {pfx}")
        publish_overlay_state("egress")
    return pfx


def rotation_in_progress():
    """True while any rotator holds the shared global lock. The tunnel is meant
    to be down for a few seconds mid-surgery; the guard must not 'repair' it
    then, or it reconnects under the rotator and logs a fake outage."""
    try:
        fh = open(GLOBAL_ROTATE_LOCK, "a+")
    except OSError:
        return False
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        fh.close()


def heal_tunnel():
    if warp_connected() and iface_v6(force=True):
        return True
    if rotation_in_progress():
        # a rotation owns warp-cli right now; it restores the tunnel itself
        return True
    log_throttled(GUARD_LOG, "tunnel-down", "tunnel down — reconnect", every=120)
    # a dead daemon answers every warp-cli verb with 'No such file or directory';
    # bring it back before asking it to connect
    ensure_daemon()
    run([WARP, "--accept-tos", "connect"], timeout=20)
    for _ in range(10):
        if warp_connected() and iface_v6(force=True):
            log(GUARD_LOG, "tunnel healthy again")
            drop_caches()
            return True
        time.sleep(2)
    if registration_id() == "????????":
        try:
            rotate(verbose=False)
            return warp_connected() and bool(iface_v6(force=True))
        except RotationBusy:
            log_throttled(GUARD_LOG, "busy-heal", "tunnel repair deferred: rotation in progress", every=60)
        except Exception as exc:
            log(GUARD_LOG, f"rotation repair failed: {exc}")
    return False


def on_wall():
    st = jload(GUARD_STATE, {})
    t = now()
    # the third-party guard tails the same log and stamps last_hop when it
    # rotates; without this, one wall burns two /64s from two watchers
    peer = int((jload(OVERLAY_STATE, {}) or {}).get("last_hop") or 0)
    if peer and t - peer < HOP_COOLDOWN:
        log_throttled(GUARD_LOG, "peer-cooldown",
                      "wall already handled by the other guard — not rotating",
                      every=HOP_COOLDOWN)
        return
    hops = [h for h in st.get("hop_times", []) if t - h < 3600]
    if t - st.get("last_hop", 0) < HOP_COOLDOWN:
        log_throttled(GUARD_LOG, "cooldown", "wall inside cooldown — not rotating", every=HOP_COOLDOWN)
        return
    # No hourly cap. A wall is the whole reason this process exists; refusing to
    # rotate because "too many hops this hour" is the bug that made the stack
    # feel broken after a long session. The burn list and the egress check keep
    # it honest; the count below is telemetry, never a gate.
    hops.append(t)
    st["hop_times"] = hops
    jsave(GUARD_STATE, st)
    notify("opencode wall", "rotating WARP /64…")
    try:
        moved, before, after = rotate(verbose=False)
        log(GUARD_LOG, f"wall rotated {before} -> {after} moved={moved}")
        notify("ocul", f"new /64 {after or 'unknown'} — resend the message")
    except RotationBusy:
        log_throttled(GUARD_LOG, "busy", "wall: rotation already in progress", every=60)
    except Exception as exc:
        log(GUARD_LOG, f"wall rotation failed: {exc}")
        notify("ocul", "rotation failed — see ocul logs")


def tail_offset(path):
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


def pump_log(path, offset):
    """Bytes written since offset. Never replays history after a gap.

    Returns (new_offset, chunk). A log that shrank (truncated/rotated) restarts
    at 0; a log that grew by more than CATCHUP_MAX jumps to the tail window so a
    guard coming back from sleep cannot relive every wall of the last week.
    """
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return 0, b""

    if size < offset:
        offset = 0
    if size - offset > CATCHUP_MAX:
        offset = max(0, size - TAIL_WINDOW)
    if size <= offset:
        return size, b""

    with open(path, "rb") as fh:
        fh.seek(offset)
        chunk = fh.read(min(size - offset, READ_CHUNK))
    return offset + len(chunk), chunk


def matched_line(chunk):
    text = chunk.decode("utf-8", "replace")
    for line in text.splitlines():
        if WALL_RE.search(line):
            return line.strip()[:200]
    return ""


def cmd_guard(args):
    """One guard at a time, for life.

    GUARD_LOCK is held for the whole process, so a second `ocul guard` (launchd
    respawning while a manual one is running, or two agents installed by mistake)
    waits quietly instead of double-tailing the log and double-rotating on the
    same wall. Waiting is cheaper than thrash: launchd's copy simply takes over
    when the manual one exits.
    """
    ensure_dirs()
    port = int(os.environ.get("OCUL_PORT", 40123))
    lock = FileLock(GUARD_LOCK)
    waited = 0
    while not lock.acquire():
        holder = ""
        try:
            holder = GUARD_LOCK.read_text().split()[0]
        except Exception:
            pass
        log_throttled(GUARD_LOG, "guard-lock",
                      f"guard already running (pid {holder or '?'}) — standing by", every=60)
        time.sleep(5)
        waited += 5
        if waited >= 300:
            log(GUARD_LOG, "guard lock held for 5m by another process — exiting so launchd can retry")
            return 0

    try:
        st = jload(GUARD_STATE, {})
        if "offset" not in st:
            # first run: the past is not our business
            st["offset"] = tail_offset(OPENCODE_LOG)
            st["offset_from"] = "tail"
            save_if_changed(GUARD_STATE, st)
        offset = int(st["offset"])
        log(GUARD_LOG,
            f"guard up pid={os.getpid()} tick={TICK}s log={OPENCODE_LOG} offset={offset}")
        publish_overlay_state("guard-up")

        ticks = 0
        while True:
            ticks += 1
            try:
                offset, chunk = pump_log(OPENCODE_LOG, offset)
                line = matched_line(chunk) if chunk else ""
                if line:
                    record_wall("detected", line)
                    on_wall()

                st = jload(GUARD_STATE, {})
                st["offset"] = offset
                st["guard_pid"] = os.getpid()
                # one write per change, not one write per tick: 14k small writes a
                # day on the same values is how guard.json ends up half-flushed
                save_if_changed(GUARD_STATE, st)

                if ticks % 5 == 0:
                    heal_tunnel()
                # the egress /64 is the quota key; a reconnect can change it
                # silently, so re-measure once a minute and keep state honest
                if ticks % 10 == 0:
                    refresh_egress()
                # keepalive: the lane spawns the proxy, but a proxy that died while
                # nobody was launching opencode must still be there at the next launch
                if ticks % 10 == 0 and not port_open(port) and not PROXY_OFF.exists():
                    if ensure_proxy(port):
                        log_throttled(GUARD_LOG, "proxy-up",
                                      f"proxy restored on {port}", every=300)
                    else:
                        log_throttled(GUARD_LOG, "proxy-down",
                                      f"proxy would not start on {port}", every=300)
                # the HUD renders these files; keep them a tick behind reality,
                # never a stack behind it
                publish_overlay_state("tick")
            except Exception as exc:
                log(GUARD_LOG, f"tick error: {exc!r}")
            time.sleep(TICK)
    finally:
        lock.release()


def cmd_hop(args):
    try:
        moved, before, after = rotate(verbose=True)
    except Exception as exc:
        print(f"rotation failed: {exc}")
        return 2
    src = iface_v6()
    fields = trace_v6(src) if src else {}
    seen = fields.get("ip", "?")
    print(f"exit   {seen}   warp={fields.get('warp','?')} colo={fields.get('colo','?')}")
    print(f"bucket {prefix64(seen) if ':' in seen else prefix64(after)}")
    print("fresh /64" if moved else "same /64 — cloudflare handed back the old block, run it again")
    return 0 if moved else 1


def cmd_edges(args):
    src = iface_v6()
    if not src:
        print("no WARP IPv6 address")
        return 2
    pool = aaaa("api.opencode.ai")
    print(f"source {src}  route {route_iface(pool[0]) if pool else '?'}")
    good = 0
    for e in pool:
        ok = probe(e, src)
        good += 1 if ok else 0
        print(f"  {'ok ' if ok else '-- '}{e}")
    print(f"{good}/{len(pool)} reachable over v6")
    return 0


def cmd_proxy_on(args):
    port = int(os.environ.get("OCUL_PORT", 40123))
    if not warp_connected() or not iface_v6(force=True):
        # never refuse a lane the user asked for: repair first, fail only if the
        # tunnel genuinely will not come back. the old refusal turned a 2 s
        # mid-rotation blip into a dead overlay.
        log(GUARD_LOG, "proxy-on: tunnel down — repairing before opening the lane")
        ensure_daemon()
        heal_tunnel()
    if not warp_connected() or not iface_v6(force=True):
        print("warp tunnel is down and could not be repaired — lane stays closed")
        return 3
    try:
        PROXY_OFF.unlink()
    except OSError:
        pass
    if not ensure_proxy(port):
        print(f"proxy did not come up on 127.0.0.1:{port}")
        return 4
    publish_overlay_state("proxy-on")
    print(f"proxy up on 127.0.0.1:{port}")
    return 0


def cmd_proxy_off(args):
    port = int(os.environ.get("OCUL_PORT", 40123))
    ensure_dirs()
    PROXY_OFF.write_text(str(now()))
    kill_proxy(port)
    publish_overlay_state("proxy-off")
    print(f"proxy stopped on 127.0.0.1:{port} (guard leaves it down until `ocul proxy-on`)")
    return 0


def cmd_overlay(args):
    if not OVERLAY_GUARD.is_dir():
        print(f"no overlay guard dir at {OVERLAY_GUARD} — the HUD is not installed")
        return 2
    res = publish_overlay_state("manual")
    if not res:
        print("overlay sync is off (OCUL_NO_OVERLAY_SYNC)")
        return 2
    px, ov = res["proxy"], res["state"]
    print(f"proxy-state  up={px['up']} pid={px['pid']} listen={px['listen']} "
          f"pool={px['pool']} served={px['served']} failed={px['failed']} "
          f"rot={px['rotations']}")
    print(f"state        prefix={ov.get('prefix') or '-'} "
          f"seen6={ov.get('seen6') or '-'} "
          f"device={(ov.get('device') or '')[:8]}… hops={ov.get('hops')} "
          f"blacklist={len(ov.get('blacklist') or [])}")
    print(f"files        {OVERLAY_PROXY_STATE}")
    print(f"             {OVERLAY_STATE}")
    return 0


def service_pids():
    rc, out, _ = run(["ps", "-Ao", "pid=,args="], timeout=8)
    found = []
    for line in out.splitlines():
        if "serve" in line and "--service" in line and "opencode" in line:
            try:
                found.append(int(line.split(None, 1)[0]))
            except ValueError:
                pass
    return found


def service_proxied(pid):
    rc, out, _ = run(["ps", "eww", "-p", str(pid), "-o", "command="], timeout=8)
    low = out.lower()
    return "https_proxy=" in low or "http_proxy=" in low


def cmd_service(args):
    """Report (and optionally reset) the shared background server.

    The CLI itself opens no quota socket: `opencode serve --service` owns it.
    A service started before the proxy export keeps that environment for its
    whole life, so every request from it leaves direct while the HUD says the
    lane is on. `--standalone` (lane default) sidesteps it; this command is for
    the shared one the third-party shell starts.
    """
    pids = service_pids()
    if not pids:
        print("service  not running — the CLI starts one on demand")
        return 0
    bad = []
    for pid in pids:
        has = service_proxied(pid)
        print(f"service  pid {pid}  proxy {'yes' if has else 'NO'}")
        if not has:
            bad.append(pid)
    if args and args[0] in ("restart", "repair"):
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
                print(f"         stopped {pid}")
            except OSError as exc:
                print(f"         could not stop {pid}: {exc}")
        print("         the next opencode launch starts a fresh service")
        return 0
    if bad:
        print("         `ocul service restart` clears it (drops live sessions);")
        print("         `ocul lane` never touches this server — it runs its own")
        return 1
    return 0


def cmd_status(args):
    st = jload(GUARD_STATE, {})
    src = iface_v6()
    fields = trace_v6(src) if src else {}
    port = int(os.environ.get("OCUL_PORT", 40123))
    h = proxy_health(port)

    print(f"warp     {warp_text() or 'unknown'}")
    print(f"source   {src or '(none)'}")
    print(f"exit     {fields.get('ip','?')}  colo {fields.get('colo','?')}  warp={fields.get('warp','?')}")
    print(f"bucket   {prefix64(fields.get('ip','')) if ':' in fields.get('ip','') else st.get('prefix')}")
    if h:
        flag = "" if h.get("proto") == PROTO else f"  STALE (proto {h.get('proto')}, want {PROTO})"
        print(f"proxy    up pid {h.get('pid')} v{h.get('version','?')} "
              f"uptime {h.get('uptime',0)}s active {h.get('active',0)}/{h.get('max_conns','?')} "
              f"total {h.get('total',0)} err {h.get('errors',0)} refused {h.get('refused',0)}{flag}")
    else:
        print(f"proxy    {'foreign listener (no ocul health)' if port_open(port) else 'down'}")
    print(f"edge     {jload(EDGE_STATE, {}).get('edge') or 'unset'}")
    print(f"guard    {'running pid %s' % guard_pid() if guard_pid() else 'not running'}")
    print(f"rotations {st.get('hops',0)}  collisions {st.get('collisions',0)}")
    return 0


def guard_pid():
    pid = jload(GUARD_STATE, {}).get("guard_pid")
    if not pid:
        return None
    try:
        os.kill(int(pid), 0)
        return pid
    except OSError:
        return None


CANONICAL_AGENTS = {
    # the one rotator, the one keeper, the HUD
    "ai.ocul.guard",
    "com.opencode-unlimited.keeper",
    "com.opencode-unlimited.overlay",
}
KNOWN_ROTATOR_LABELS = {
    "ai.ocul.guard": "ocul guard (canonical rotator)",
    "com.ouc.guard": "opencode-unlimited-mac python guard — DUPLICATE rotator",
    "com.ouc.keeper": "opencode-unlimited-mac python keeper — DUPLICATE keeper",
    "com.opencode-unlimited.guard": "legacy shell guard — DUPLICATE rotator",
    "com.opencode-unlimited.keeper": "warp-keeper.sh root daemon (canonical keeper)",
    "com.opencode-unlimited.overlay": "overlay HUD",
}


def running_agents():
    """Which warp-driving launchd agents are live on this Mac. Two rotators on
    one machine is the bug behind every 'rotation does not work' report: they
    both delete the same registration and one lands the tunnel down."""
    uid = os.getuid()
    live = []
    for label, desc in KNOWN_ROTATOR_LABELS.items():
        domain = "system" if label == "com.opencode-unlimited.keeper" else f"gui/{uid}"
        rc, out, _ = run(["launchctl", "print", f"{domain}/{label}"], timeout=6)
        if rc == 0 and "state = running" in out:
            live.append((label, desc))
    return live


def cmd_doctor(args):
    ok = lambda m: print(f"  ✓ {m}")
    warn = lambda m: print(f"  ! {m}")
    bad = lambda m: print(f"  ✗ {m}")
    src = iface_v6()
    st = jload(GUARD_STATE, {})
    fields = trace_v6(src) if src else {}
    seen = fields.get("ip", "")
    edge = jload(EDGE_STATE, {}).get("edge")

    print("\n  ocul doctor — macOS\n")
    (ok if warp_connected() else bad)(f"warp tunnel: {warp_text() or 'unknown'}")
    (ok if src else bad)(f"warp source address: {src or 'none (no tunnel v6)'}")
    if src:
        probe_edge = (jload(EDGE_STATE, {}).get("edge")
                      or (aaaa("api.opencode.ai") or ["2606:4700:4700::1111"])[0])
        (ok if route_iface(probe_edge) else bad)(
            f"route to edge {probe_edge}: {route_iface(probe_edge) or 'none'}"
        )
    (ok if registered() else warn)(f"registration: {registration_id()[:13]}…")
    (ok if ":" in seen else warn)(
        f"server-seen ip: {seen or 'unmeasured'}  warp={fields.get('warp','?')}"
    )
    if ":" in seen:
        tracked = st.get("egress_prefix")
        (ok if (not tracked or prefix64(seen) == tracked) else warn)(
            f"quota key /64: {prefix64(seen)}  (state has {tracked or 'unrecorded'})"
            + ("" if (not tracked or prefix64(seen) == tracked)
               else "  — guard refreshes this within a minute")
        )
    (ok if edge else warn)(f"pinned edge: {edge or 'not chosen yet'}")
    port = int(os.environ.get("OCUL_PORT", 40123))
    health = proxy_health(port)
    if health and health.get("proto") == PROTO:
        ok(f"proxy: 127.0.0.1:{port} pid {health['pid']} v{health.get('version','?')} "
           f"uptime {health.get('uptime',0)}s active {health.get('active',0)} "
           f"total {health.get('total',0)} err {health.get('errors',0)}")
    elif health:
        warn(f"proxy: stale build on {port} (proto {health.get('proto')}, want {PROTO}) — ocul lane replaces it")
    elif port_open(port):
        warn(f"proxy: something else is listening on {port} (no ocul health route)")
    else:
        warn(f"proxy: down — ocul lane spawns it")
    pid = guard_pid()
    (ok if pid else warn)(f"guard: {('pid %s' % pid) if pid else 'not running — ocul install'}")

    # more than one rotator is the root cause of the race that leaves the tunnel
    # down and paints the enrollment page. surface it loudly, never silently.
    live = running_agents()
    dupes = [d for label, d in live if label not in CANONICAL_AGENTS]
    if dupes:
        bad(f"{len(live)} warp agents running — {len(dupes)} that race ocul:")
        for d in dupes:
            print(f"      • {d}")
        print("      fix: run `ouctl consolidate` (removes the duplicates)")
    else:
        ok(f"warp agents: {len(live)} ({', '.join(l for l, _ in live) or 'none'})")
    (ok if OPENCODE_LOG.exists() else warn)(
        f"opencode log: {OPENCODE_LOG if OPENCODE_LOG.exists() else 'missing'}"
    )
    print(f"    offset {st.get('offset',0)}  rotations {st.get('hops',0)}  collisions {st.get('collisions',0)}")
    if WALLS.exists():
        tail = WALLS.read_text().strip().splitlines()[-1:]
        if tail:
            try:
                last = json.loads(tail[0])
                print(f"    last wall {time.strftime('%m-%d %H:%M', time.localtime(last['ts']))} — {last['what']} {last.get('extra','')}")
            except Exception:
                pass
    la = HOME / "Library/LaunchAgents/ai.ocul.guard.plist"
    (ok if la.exists() else warn)(f"launchd agent: {la if la.exists() else 'not installed'}")
    print()
    return 0


PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.ocul.guard</string>
  <key>ProgramArguments</key>
  <array>
    <string>{launcher}</string><string>guard</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>20</integer>
  <key>StandardOutPath</key><string>{state}/guard.out</string>
  <key>StandardErrorPath</key><string>{state}/guard.out</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:{home}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>OCUL_PORT</key><string>{port}</string>
  </dict>
</dict>
</plist>
"""

# The launcher is the single entry point, and it finds python itself. A hard
# path to the interpreter is what orphans a launchd agent the day Homebrew
# upgrades python@3.13 and the old Cellar path disappears.
LAUNCHER = """#!/bin/bash
# ocul — opencode unlimited lane. Generated by `ocul install`; edit ocul.py instead.
script="{script}"
for py in "${{OCUL_PYTHON:-}}" python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [ -n "$py" ] || continue
  if command -v "$py" >/dev/null 2>&1; then exec "$py" "$script" "$@"; fi
done
echo "ocul: no python3 on PATH — install python3 or set OCUL_PYTHON" >&2
exit 127
"""


def cmd_install(args):
    ensure_dirs()
    script = Path(__file__).resolve()
    port = int(os.environ.get("OCUL_PORT", 40123))

    binp = HOME / ".local/bin/ocul"
    binp.parent.mkdir(parents=True, exist_ok=True)
    binp.write_text(LAUNCHER.format(script=script))
    binp.chmod(0o755)

    la = HOME / "Library/LaunchAgents/ai.ocul.guard.plist"
    la.parent.mkdir(parents=True, exist_ok=True)
    la.write_text(
        PLIST.format(launcher=binp, state=STATE, home=HOME, port=port)
    )
    uid = os.getuid()
    run(["launchctl", "bootout", f"gui/{uid}/ai.ocul.guard"], timeout=20)
    rc, out, err = run(["launchctl", "bootstrap", f"gui/{uid}", str(la)], timeout=20)
    # bootstrap starts the job because RunAtLoad is true; kickstart -k pays a
    # full kill+spawn and its wait outlives the CLI's own deadline on this box.
    started = False
    for _ in range(12):
        time.sleep(0.4)
        prc, pout, _ = run(["launchctl", "print", f"gui/{uid}/ai.ocul.guard"], timeout=8)
        if prc == 0 and "state = running" in pout:
            started = True
            break

    if not port_open(port):
        ensure_proxy(port)

    print(f"launcher  {binp}")
    print(f"agent     {la}")
    print(f"state     {STATE}")
    print(f"python    {sys.executable}")
    if not started:
        print(f"launchd   {err or out or 'job did not reach running'}")
        print("          fallback: run `ocul guard` under your own supervisor")
    print("\nnext:")
    print("  ocul doctor")
    print("  ocul lane            # or point your own wrapper at it")
    return 0


def cmd_uninstall(args):
    uid = os.getuid()
    port = int(os.environ.get("OCUL_PORT", 40123))
    run(["launchctl", "bootout", f"gui/{uid}/ai.ocul.guard"], timeout=15)
    for p in (HOME / "Library/LaunchAgents/ai.ocul.guard.plist", HOME / ".local/bin/ocul"):
        if p.exists():
            p.unlink()
            print(f"removed {p}")

    if kill_proxy(port):
        print(f"stopped proxy on {port}")
    pid = jload(GUARD_STATE, {}).get("guard_pid")
    if pid:
        try:
            os.kill(int(pid), signal.SIGTERM)
            print(f"stopped guard pid {pid}")
        except OSError:
            pass
    for p in (PROXY_PID, GUARD_LOCK, ROTATE_LOCK):
        try:
            p.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            print(f"could not remove {p}: {exc}")
    print("left in place: " + str(ROOT) + " and " + str(STATE) + " (delete by hand)")
    return 0


def main(argv):
    # lane owns its argv outright: everything after `lane` is opencode's, and
    # argparse's REMAINDER reorders single-dash flags before they get there.
    if argv and argv[0] == "lane":
        return cmd_lane(argv[1:])

    ap = argparse.ArgumentParser(prog="ocul", add_help=True)
    ap.add_argument("--version", action="version",
                    version=f"ocul {VERSION} (proto {PROTO})")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("doctor")
    sub.add_parser("status")
    sub.add_parser("hop")
    sub.add_parser("edges")
    sub.add_parser("overlay", help="publish ocul state into the overlay HUD files")
    sub.add_parser("proxy-on", help="start the lane proxy (HUD PROXY chip)")
    sub.add_parser("proxy-off", help="stop the lane proxy and keep it down")
    p = sub.add_parser("service", help="report/restart the shared opencode server")
    p.add_argument("action", nargs="?", choices=["status", "restart", "repair"], default="status")
    sub.add_parser("guard")
    sub.add_parser("install")
    sub.add_parser("uninstall")
    sub.add_parser("lane", help="run opencode through the lane (args pass through)")
    p = sub.add_parser("proxy")
    p.add_argument("--port", type=int, default=int(os.environ.get("OCUL_PORT", 40123)))

    if not argv:
        argv = ["status"]
    args, rest = ap.parse_known_args(argv)

    if args.cmd == "doctor":
        return cmd_doctor(args)
    if args.cmd == "status":
        return cmd_status(args)
    if args.cmd == "hop":
        return cmd_hop(args)
    if args.cmd == "edges":
        return cmd_edges(args)
    if args.cmd == "overlay":
        return cmd_overlay(args)
    if args.cmd == "proxy-on":
        return cmd_proxy_on(args)
    if args.cmd == "proxy-off":
        return cmd_proxy_off(args)
    if args.cmd == "service":
        return cmd_service([args.action])
    if args.cmd == "proxy":
        return cmd_proxy(args)
    if args.cmd == "guard":
        return cmd_guard(args)
    if args.cmd == "install":
        return cmd_install(args)
    if args.cmd == "uninstall":
        return cmd_uninstall(args)
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
