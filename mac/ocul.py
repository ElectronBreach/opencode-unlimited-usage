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
# the App Support state.json predates ocul and is still read by status.sh,
# doctor.sh and the older `ouc` CLI. nothing writes it any more, so its
# current_64 froze and every panel that preferred it showed the previous /64
# forever. ocul now mirrors the live egress there on every publish.
LEGACY_APP = Path(os.environ.get(
    "OCUL_LEGACY_APP", HOME / "Library/Application Support/opencode-unlimited"))
LEGACY_STATE = LEGACY_APP / "state.json"
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
# buckets reset roughly daily. keep the newest, drop the fossils.
BLACKLIST_CAP = 64
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

    def acquire(self, timeout=0.0, poll=0.2):
        """Take the lock, waiting up to `timeout` seconds for it.

        This used to try exactly once and give up. A HUD hop that landed while
        the guard was mid-surgery therefore printed

            rotation failed: another rotator holds the global lock

        for work that was already happening — the panel reported a fault for a
        system doing exactly what it should. A flock is released by the kernel
        the instant the holder exits, so there is no stale case worth forcing:
        the honest answer is to wait, then decide. `timeout=0` keeps the old
        non-blocking behaviour for callers that want it (rotation_in_progress).
        """
        ensure_dirs()
        deadline = time.monotonic() + max(0.0, float(timeout))
        while True:
            fh = None
            try:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                fh = open(self.path, "a+")
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                if fh is not None:
                    try:
                        fh.close()
                    except OSError:
                        pass
                if time.monotonic() >= deadline:
                    return False
                time.sleep(poll)
                continue
            self.fh = fh
            self.fh.seek(0)
            self.fh.truncate()
            self.fh.write(f"{os.getpid()} {stamp()}\n")
            self.fh.flush()
            return True
        # unreachable

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


ROTATE_OWNER = STATE / "rotate.owner.json"


def lock_holder(path):
    """(pid, age_seconds) of whoever last stamped a FileLock, best effort.

    The flock itself is invisible from outside, so the pid the holder wrote and
    the file's mtime are the only honest evidence. Used to say *who* owns the
    tunnel instead of "another rotator" — a message the user can act on.
    """
    pid = 0
    try:
        pid = int(Path(path).read_text().split()[0])
    except Exception:
        pid = 0
    try:
        age = max(0, int(time.time() - Path(path).stat().st_mtime))
    except OSError:
        age = 0
    return pid, age


LAST_MODE = {"mode": ""}


def mark_rotation_phase(phase, extra=None):
    """Publish what the in-flight rotation is doing.

    The HUD, `ocul status` and a second `ocul hop` all read this. Without it a
    few minutes of legitimate surgery is indistinguishable from a wedged
    process, and the user's only lever is clicking HOP harder.
    """
    prev = rotation_phase()
    # `started` belongs to the attempt, not to the phase line: rewriting it on
    # every round made a two-minute rotation report "0s in".
    try:
        started = int(prev.get("started") or 0) if int(prev.get("pid") or 0) == os.getpid() else 0
    except Exception:
        started = 0
    data = {"pid": os.getpid(), "phase": phase, "started": started or now()}
    if extra:
        data.update(extra)
    try:
        jsave(ROTATE_OWNER, data)
    except Exception:
        pass


def clear_rotation_phase():
    try:
        ROTATE_OWNER.unlink()
    except OSError:
        pass


ROTATE_MAX_AGE = 1800


def rotation_phase():
    """The in-flight rotation, or {} when the owner file is a fossil.

    A rotator killed with SIGKILL never reaches its `finally`, so
    rotate.owner.json outlives it. Every reader then believes the tunnel is
    owned for ever: the HUD gates HOP behind "rotation in progress", health
    prints "do not click HOP", the guard holds walls instead of acting on
    them, and a second `ocul hop` defers to a process that no longer exists.
    The pid decides — and a hard age cap decides when that pid was reused by
    something unrelated. One check here is worth one in each of the four
    readers, which is how they drifted apart in the first place.
    """
    d = jload(ROTATE_OWNER, {}) or {}
    if not d:
        return {}
    try:
        pid = int(d.get("pid") or 0)
    except Exception:
        pid = 0
    try:
        started = int(d.get("started") or 0)
    except Exception:
        started = 0

    alive = False
    if pid > 0:
        try:
            os.kill(pid, 0)
            alive = True
        except ProcessLookupError:
            alive = False
        except PermissionError:
            # the process exists and belongs to someone else — still a live
            # owner, and not ours to clear
            alive = True
        except Exception:
            alive = False

    aged = bool(started) and (now() - started) > ROTATE_MAX_AGE
    if alive and not aged:
        return d

    try:
        ROTATE_OWNER.unlink()
    except OSError:
        pass
    log_throttled(GUARD_LOG, "rot-owner-fossil",
                  f"cleared a dead rotation owner (pid {pid or '?'}, "
                  f"{max(0, now() - started)}s old) — the tunnel is free",
                  every=120)
    return {}


def api_park_left():
    """Seconds the shared `warp api busy` parking order has left.

    Cloudflare throttles registration creation, and every rotator on the box
    used to discover that independently: 14 attempts at 45 s each, twice over,
    per wall. The stamp makes one process' throttle teach the others, which is
    the difference between "stalled for 40 minutes" and "waited two".
    """
    st = jload(GUARD_STATE, {}) or {}
    return max(0, int(st.get("api_busy_until") or 0) - now())


def park_api(seconds, why=""):
    seconds = int(max(5, min(900, seconds)))
    st = jload(GUARD_STATE, {}) or {}
    until = now() + seconds
    if int(st.get("api_busy_until") or 0) >= until:
        return
    st["api_busy_until"] = until
    jsave(GUARD_STATE, st)
    log(GUARD_LOG, f"warp api throttled — rotations parked {seconds}s ({why or 'busy'})")


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


def trace_v6(src, edge=None, probe_timeout=None):
    """What the server sees, measured on the same path the lane uses.

    A single pinned edge that happens to be unreachable does not mean "there is
    no egress" — it means "we could not measure it this second". Trying a few
    edges keeps a dead one from making refresh_egress read a fresh /64 as a
    drift to empty (which then burns a rotation correcting a phantom).
    """
    if not src:
        return {}
    cands = []
    if edge:
        cands.append(edge)
    try:
        cands.extend(aaaa(TRACE_HOST)[:3])
    except Exception:
        pass
    cands.append("2606:4700::6810:84e5")
    seen = set()
    tries = 0
    # cap the sweep: this runs on the guard tick and in rotate(), never in the
    # proxy's per-request path, but a fully-down trace must still not stall the
    # guard for half a minute. three edges at 4s is a bounded worst case.
    timeout = probe_timeout or min(CONNECT_TIMEOUT, 4.0)
    for target in cands:
        if tries >= 3:
            break
        if not target or target in seen:
            continue
        seen.add(target)
        tries += 1
        s = None
        try:
            s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.bind((src, 0))
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
            if fields.get("ip"):
                return fields
        except (OSError, ssl.SSLError):
            if s is not None:
                try:
                    s.close()
                except Exception:
                    pass
            continue
    return {}


# ---- egress measurement -----------------------------------------------------
# Two questions, one answer. `www.cloudflare.com/cdn-cgi/trace` names the exit
# *and* whether WARP is carrying it (`warp=on`) — the only source that does.
# When that host is the broken thing, or when it says the traffic bypassed the
# tunnel, a plain echo from a different operator names the address instead.
# One source failing is a bad minute, not a new /64.
ECHO_HOSTS = ("icanhazip.com", "api64.ipify.org")
EGRESS_TTL = 8.0
EGRESS_BUDGET = 9.0         # whole measurement, trace + corroboration
EGRESS_PROBE_TIMEOUT = 2.5  # per socket, so three dead edges cost 7.5s not 12
_EGRESS_CACHE = {"src": None, "ts": 0.0, "info": {}}
_EGRESS_LOCK = threading.Lock()
# drift confirmation: one reading arms, two agree, three changes in ten minutes
# means the tunnel is moving under us rather than Cloudflare re-pinning.
_DRIFT = {"pfx": "", "n": 0, "events": []}


def _probe_body(src, host, path="/", timeout=None, hostname=None):
    """One HTTPS GET over the tunnel, bound to the WARP source address."""
    timeout = timeout or min(CONNECT_TIMEOUT, 4.0)
    if host.count(":") >= 3:
        target = host
    else:
        try:
            target = next((a for a in aaaa(host)[:3] if a), "")
        except Exception:
            target = ""
    if not target:
        return ""
    s = None
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.bind((src, 0))
        s.connect((target, 443))
        tls = ssl.create_default_context().wrap_socket(
            s, server_hostname=hostname or host)
        tls.sendall(f"GET {path} HTTP/1.1\r\nHost: {hostname or host}\r\n"
                    "User-Agent: ocul\r\nConnection: close\r\n\r\n".encode())
        raw = b""
        while len(raw) < 65536:
            chunk = tls.recv(4096)
            if not chunk:
                break
            raw += chunk
        tls.close()
        return raw.split(b"\r\n\r\n", 1)[-1].decode("latin1").strip()
    except (OSError, ssl.SSLError):
        if s is not None:
            try:
                s.close()
            except Exception:
                pass
        return ""


def measure_egress(src=None, force=False, cache_ttl=EGRESS_TTL):
    """Where the far end says we are coming from — measured, not assumed.

    Returns {"ip", "prefix", "colo", "warp", "loc", "sources", "unstable", "ts"}
    or {} when nothing could be measured. An empty answer is a *fact* ("not
    reachable right now"), never a licence to fall back to the utun leg.

    Cached briefly and single-flighted: the guard tick, the HUD's `where` and a
    rotation all ask, and three simultaneous probes of the same source address
    is three ways to get a half-open connection and call it drift.
    """
    src = src or iface_v6(force=True)
    if not src:
        return {}
    c = _EGRESS_CACHE
    if not force and c["info"] and c["src"] == src \
            and time.monotonic() - c["ts"] < cache_ttl:
        return c["info"]
    if not _EGRESS_LOCK.acquire(timeout=15):
        return c["info"] or {}
    try:
        if not force and c["info"] and c["src"] == src \
                and time.monotonic() - c["ts"] < cache_ttl:
            return c["info"]
        # one tick must not spend half a minute measuring. the whole reading is
        # budgeted: probe, corroborate, give up — in that order, against a clock.
        t0 = time.monotonic()
        deadline = t0 + EGRESS_BUDGET
        fields = trace_v6(src, probe_timeout=EGRESS_PROBE_TIMEOUT) or {}
        ip = fields.get("ip") if ":" in (fields.get("ip") or "") else ""
        sources = ["trace"] if ip else []
        unstable = False
        # ask a second operator when the trace is silent, or when it reports the
        # traffic did not go through the tunnel — that block is the ISP, not an
        # exit we can rotate or burn.
        if not ip or fields.get("warp") == "off":
            echo = ""
            for host in ECHO_HOSTS:
                left = deadline - time.monotonic()
                if left <= 0.8:
                    break
                body = _probe_body(src, host, timeout=min(EGRESS_PROBE_TIMEOUT, left))
                cand = (body.split() or [""])[0] if body else ""
                if ":" in cand:
                    echo = cand
                    break
            if echo:
                sources.append("echo")
                if not ip:
                    ip = echo
                elif prefix64(echo) != prefix64(ip):
                    # the exit moved while we were asking. that is a retry, not
                    # a new block, and not drift.
                    unstable = True
                if fields.get("warp") == "off":
                    # the trace says this traffic did not go through the tunnel:
                    # the address it named is the ISP. the echo was bound to the
                    # utun source, so that is the tunnel's answer — take it, and
                    # say plainly that the trace disagreed.
                    ip, unstable = echo, True
        if not ip:
            _EGRESS_CACHE.update(src=src, ts=time.monotonic(), info={})
            return {}
        info = {"ip": ip, "prefix": prefix64(ip),
                "colo": fields.get("colo") or "",
                "warp": fields.get("warp") or "",
                "loc": fields.get("loc") or "",
                "sources": sources, "unstable": unstable,
                "ms": int((time.monotonic() - t0) * 1000),
                "ts": time.time()}
        _EGRESS_CACHE.update(src=src, ts=time.monotonic(), info=info)
        return info
    finally:
        _EGRESS_LOCK.release()


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
    """Wait for the WARP root daemon's socket.

    The daemon (`com.cloudflare.1dot1dot1dot1.macos.warp.daemon`) is a root
    LaunchDaemon with KeepAlive=true, so launchd restarts it on its own after a
    blip — it does not need the front-end app to be launched to come back.

    Opening WARP.app to "resurrect the daemon" was the wrong lever: the app is
    what calls IpcStatus and paints "Something went wrong. Please try again
    later." when the registration is missing, which is exactly the state during
    a rotation. Waiting is free and produces no window.
    """
    if daemon_alive():
        return True
    deadline = time.time() + 45
    while time.time() < deadline:
        time.sleep(2)
        if daemon_alive():
            log(GUARD_LOG, "warp daemon back up (restarted by launchd)")
            return True
    log(GUARD_LOG, "warp daemon still unreachable after 45s — leaving the GUI alone")
    return False


def _gui_running():
    rc, _, _ = run(
        ["pgrep", "-f", f"{WARP_APP}/Contents/MacOS/Cloudflare WARP"], timeout=8
    )
    return rc == 0


def pause_gui(need_outage=False):
    """Close the WARP window only when the registration is about to be deleted.

    A rotate-keys rotation never drops the tunnel: the daemon mints a new key
    pair on the same registration and the edge hands back a different /64. The
    window stays open, stays connected, and there is nothing to reopen and
    nothing to click — which is the fix for "after a rotation I have to open
    WARP by hand".

    A device burn is the other case: the registration is deleted, so the window
    would sit on a browser hand-off that no longer exists and paint
    "Awaiting external log in". There it is closed once, gracefully, and put
    back by resume_gui() after the tunnel is healthy again.
    """
    if not need_outage:
        return False
    was_up = _gui_running()
    if was_up:
        quit_warp_gui()
    return was_up


def gui_age():
    """(pid, seconds alive) of the WARP front-end, or (None, 0)."""
    rc, out, _ = run(["pgrep", "-f", f"{WARP_APP}/Contents/MacOS/Cloudflare WARP"],
                     timeout=6)
    if rc != 0 or not out.strip():
        return None, 0
    pid = out.split()[0].strip()
    rc2, et, _ = run(["ps", "-o", "etimes=", "-p", pid], timeout=6)
    try:
        age = int(et.strip() or 0)
    except ValueError:
        age = 0
    return (int(pid) if pid.isdigit() else None), max(0, age)


def gui_stuck_login():
    """True when the window is parked on a login flow that can never finish.

    The tell is simple and local: the front-end is up, the daemon says the
    tunnel is down, and nothing about that changes. Right after a registration
    swap the registration can legitimately be missing for a few seconds, so a
    window younger than ~20 s on a live registration is left alone; anything
    older is the dead dialog and gets closed.
    """
    pid, age = gui_age()
    if not pid:
        return False
    if warp_connected():
        return False
    if not registered():
        return age >= 5
    return age >= 20


def heal_login(force=False):
    """Close a dead login dialog and put the tunnel back up behind it.

    The window is a viewer, but it is also the only thing the user can see.
    Two ways this used to end with the user clicking the dock icon by hand:

    - `heal_tunnel()` calls this with force on every tunnel blip, and force
      quit the window unconditionally. A rotate-keys hop drops the tunnel for
      a second, the guard tick lands in that second, and the window is gone
      for a rotation that never needed it closed.
    - nothing reopened what it closed.

    So: quit the window only when the dialog is genuinely stuck, never while a
    rotation owns the tunnel, and put back exactly the window that was there.
    """
    if rotation_phase():
        # a rotation closes and reopens the window itself. closing it here
        # mid-surgery is how a hop ended with a tunnel up and no window.
        return False
    stuck = gui_stuck_login()
    if not (force or stuck):
        return False
    was_up = _gui_running()
    if stuck:
        log_throttled(GUARD_LOG, "gui-login",
                      "WARP window parked on a dead login flow — closing it and reconnecting",
                      every=300)
        quit_warp_gui()
    else:
        # a blip is not a login flow. reconnect behind the window.
        log_throttled(GUARD_LOG, "login-flow-blip",
                      "tunnel blipped — reconnecting without closing the window",
                      every=300)
    ensure_daemon()
    if not registered():
        run([WARP, "--accept-tos", "registration", "new"], timeout=60)
    run([WARP, "--accept-tos", "connect"], timeout=25)
    for _ in range(15):
        if warp_connected() and iface_v6(force=True):
            drop_caches()
            log(GUARD_LOG, "login flow cleared — tunnel up"
                + (", window put back" if (stuck and was_up) else ""))
            if stuck and was_up:
                # there is a working tunnel now, which is the only state the
                # window may be launched into
                resume_gui(True)
            return True
        time.sleep(2)
    return False


def resume_gui(was_up):
    """Put the window back on a tunnel that already works, and prove it opened.

    Order is the whole fix. Launching WARP.app while the registration is
    missing paints "Awaiting external log in"; launching it after the tunnel is
    up simply shows a connected client. Two things the first version got wrong,
    and both of them ended with the user clicking the dock icon by hand:

    - `open -a` is not a guarantee. If the previous front-end is still
      terminating, LaunchServices hands the request to the dying instance and
      no window appears; if the app is alive with its window closed, only a
      reopen event brings the window back. So it retries, and it checks that a
      process exists afterwards instead of trusting the exit code.
    - a window behind other apps is the same as a window that is not there for
      anyone who is not looking for it. `activate` brings it forward.

    Runs only when the window was actually closed by pause_gui(); a rotate-keys
    rotation never closes it, which is why most rotations need no click at all.
    """
    if not was_up:
        return False
    # the tunnel first: a window on a dead registration is worse than none
    for _ in range(12):
        if warp_connected() and iface_v6(force=True):
            break
        time.sleep(2.5)
    else:
        log_throttled(GUARD_LOG, "gui-reopen-late",
                      "WARP window: tunnel not up yet — reopening anyway, once",
                      every=300)
    if _gui_running():
        log_throttled(GUARD_LOG, "gui-already-up",
                      "WARP window was still up — raising it", every=300)
    for try_no in range(1, 4):
        rc, _, err = run(["open", "-a", WARP_APP], timeout=15)
        if rc == 0:
            for _ in range(16):
                if _gui_running():
                    run(["osascript", "-e",
                         'tell application "Cloudflare WARP" to activate'], timeout=10)
                    log_throttled(GUARD_LOG, "gui-reopen",
                                  f"WARP window reopened (try {try_no})", every=60)
                    return True
                time.sleep(0.5)
        time.sleep(1.5 + try_no)
    log_throttled(GUARD_LOG, "gui-reopen-fail",
                  f"WARP window would not reopen: {(err or 'no process')[:80]}",
                  every=600)
    return False


def quit_warp_gui():
    """Close the WARP window without killing it in a loop.

    `pkill` in a watchdog is what used to manufacture the stuck dialog: launchd
    resurrected the front-end *while the registration was missing*, it called
    IpcStatus.missingRegistration(), and it sat on

        Awaiting external log in — complete your login in the secure browser
        window that opened

    for ever, because that browser flow was invalidated by the surgery. One
    graceful quit, then one plain kill only if the app ignored it, is enough.
    Nothing reopens it: the tunnel is a daemon, the window is a viewer.
    """
    if not _gui_running():
        return False
    run(["osascript", "-e", 'tell application "Cloudflare WARP" to quit'], timeout=12)
    deadline = time.time() + 6
    while time.time() < deadline and _gui_running():
        time.sleep(0.4)
    if _gui_running():
        run(["pkill", "-f", f"{WARP_APP}/Contents/MacOS/Cloudflare WARP"], timeout=8)
        time.sleep(1.0)
    return True


GUI_HOLD = STATE / "gui-hold"


def hold_gui_down():
    """No longer used.

    This ran a watchdog pkill loop for the whole surgery so launchd could not
    bring the window back mid-rotation. It worked, but it also guaranteed that
    the *next* WARP.app process started at the worst possible moment — right
    after the registration was deleted — which is what painted
    "Something went wrong. Please try again later." and kept it.

    With nothing killing the GUI there is nothing for launchd to resurrect, so
    there is no fresh front-end during surgery and no stale page. Returns None
    so the call site stays shape-compatible.
    """
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
    # deliberately no resume: see pause_gui()


def rotate(verbose=True, lock_timeout=30, cheap_first=True):
    """Take a fresh egress /64, confirm it moved, come back up.

    Serialised on three levels, in fixed order:
      1. GLOBAL_ROTATE_LOCK — the flock every rotator on this Mac shares.
      2. ROTATE_LOCK — ocul's own.
      3. OVERLAY_GUARD/rotate.lock — the mkdir the shell stack (zen-hop) takes.

    `lock_timeout` seconds are spent *waiting* for a peer rotation instead of
    failing: the guard and the HUD button routinely want the tunnel at the same
    moment, and the second one used to print a failure for work already in
    flight. Waiting is bounded by the caller (the HUD's watchdog), so a wedged
    holder still ends the wait — it just does not end it in the first 200 ms.

    `cheap_first` tries a plain reconnect before burning the registration. The
    quota key is the egress /64 and WARP re-pins an existing registration to a
    new block often enough that this clears a large share of walls with zero
    WARP API calls. Those calls are the scarce resource: the API throttles
    registration creation, and a throttled rotator is a rotator that stops
    working for tens of minutes. Burn second, not first.
    """
    glock = FileLock(GLOBAL_ROTATE_LOCK)
    if not glock.acquire(timeout=lock_timeout):
        pid, age = lock_holder(GLOBAL_ROTATE_LOCK)
        raise RotationBusy(
            f"a rotation is already running (pid {pid or '?'}, {age}s in) — it owns the tunnel")
    lock = FileLock(ROTATE_LOCK)
    if not lock.acquire(timeout=5):
        glock.release()
        raise RotationBusy("rotation already in progress (another guard or hop)")

    try:
        foreign = acquire_foreign_rotlock()
    except Exception:
        lock.release()
        glock.release()
        raise

    mark_rotation_phase("starting", {"max": 14})
    paused = pause_keeper()
    try:
        GUI_HOLD.unlink()
    except OSError:
        pass
    # the window is only in danger once the registration is deleted, so the
    # cheap pass never touches it. gui_was_up is decided at burn time; want_gui
    # is decided now, because a hop the user clicked is a request for the
    # window and a background rotation only restores what it found.
    gui_was_up = False
    want_gui = _gui_running() or os.environ.get("OCUL_USER_HOP") == "1"
    gui_hold = hold_gui_down()
    try:
        if not ensure_daemon():
            raise RuntimeError("warp daemon is not running")

        before_addr = iface_v6(force=True)
        before_pfx = prefix64(before_addr)

        st = jload(GUARD_STATE, {})
        burned = set((jload(OVERLAY_STATE, {}) or {}).get("blacklist") or [])
        # The bucket we are leaving is what the far end says *right now*, not
        # what the guard last wrote. WARP moves the exit on a plain reconnect, so
        # a guard that is one minute behind would have us compare a fresh block
        # against a stale one and call the block we are already on "fresh".
        # before_pfx is the utun leg (2606:4700:110:…) — a state address, never
        # an exit — so it is never a candidate for this.
        here = measure_egress(before_addr, force=True) if before_addr else {}
        old_bucket = here.get("prefix") or st.get("egress_prefix") or ""
        old_from = ("measured" if here.get("prefix")
                    else ("state" if old_bucket else "unknown"))
        if old_bucket:
            burned.add(old_bucket)

        say = print if verbose else (lambda *a, **k: None)
        say(f"old {old_bucket or '(unmeasured)'} ({old_from})"
            f"  tunnel {before_pfx or '(down)'}  device {registration_id()[:8]}…")

        def measure():
            """(tunnel addr, tunnel /64, egress ip, egress /64) as seen remotely.

            One code path for every measurement in the rotator: retried, cached
            per source address, corroborated by a second operator when the trace
            host is the broken thing. An unstable reading (the exit moved while
            we asked) is re-taken once before it is allowed to decide anything.
            """
            addr = iface_v6(force=True)
            if not addr:
                return "", "", None, ""
            m = measure_egress(addr, force=True)
            if m.get("unstable"):
                time.sleep(1.0)
                m = measure_egress(addr, force=True)
            return (addr, prefix64(addr), (m.get("ip") or None),
                    (m.get("prefix") or ""))

        def settled(seconds=40):
            deadline = time.time() + seconds
            while time.time() < deadline:
                if warp_connected() and iface_v6(force=True):
                    return True
                time.sleep(1.5)
            return False

        # Cheap pass first. A plain reconnect re-pins the existing registration
        # to a new /64 often enough to clear most walls with zero WARP API
        # calls, and those calls are the throttled resource: a rotator that
        # hammers registration/new spends the next forty minutes parked. Burn
        # the device only when the reconnect genuinely handed the same block
        # back.
        if cheap_first and not api_park_left():
            # the phase is published per round, never before the loop binds
            # `round_no` — referencing it here raised UnboundLocalError and
            # killed the cheap pass before its first call.
            say("-- cheap pass: rotate the tunnel key pair, stay connected --")
            last_key = old_bucket
            api_refused = 0
            for round_no in range(1, 3):
                mark_rotation_phase("rotate-keys",
                                    {"attempt": round_no, "max": 2,
                                     "old": old_bucket})
                # `tunnel rotate-keys` mints a new key pair on the SAME
                # registration. The edge hands back a different egress /64,
                # the tunnel never drops, and no registration is burned — the
                # one resource Cloudflare throttles. This is the pass that
                # should clear most walls; measuring proves whether it did.
                rc, out, err = run([WARP, "--accept-tos", "tunnel", "rotate-keys"],
                                   timeout=30)
                if rc != 0:
                    msg = (out + " " + err).strip()
                    if api_busy(msg):
                        park_api(25, "tunnel rotate-keys")
                        api_refused += 1
                    say(f"   key rotation {round_no}/2 refused: {msg[:80] or 'error'}")
                    time.sleep(3 + round_no)
                    continue
                if not settled(20):
                    say("   tunnel did not settle — moving to the device burn")
                    break
                c_addr, c_pfx, c_egress, c_key = measure()
                if c_key and c_key != old_bucket and c_key not in burned:
                    did = registration_id()
                    _OVERLAY_DEV.update(id=did, ts=time.time())
                    st.update({"last_hop": now(), "hops": st.get("hops", 0) + 1,
                               "prefix": c_pfx, "addr": c_addr,
                               "egress": c_egress, "egress_prefix": c_key,
                               "egress_seen": int(time.time()), "collisions": 0})
                    jsave(GUARD_STATE, st)
                    drop_caches()
                    record_wall("rotated", f"egress {c_key} via rotate-keys "
                                           f"(device {before_pfx})")
                    overlay_rotate(old_bucket, c_key, did)
                    publish_overlay_state("rotate")
                    LAST_MODE["mode"] = "rotate-keys"
                    mark_rotation_phase("done", {"moved": c_key})
                    say(f"bucket {c_key}  tunnel {c_pfx}"
                        f"  (rotate-keys, no device burn)")
                    return True, before_pfx, c_pfx
                last_key = c_key or last_key
                say(f"   key rotation {round_no}/2 kept {last_key or '?'}")
            if api_refused >= 2:
                # the WARP API is throttling us. Burning the device needs the
                # same API, so it would only delete a working registration and
                # sit in the dark until the park lifts. Keep the tunnel.
                left = api_park_left()
                raise RuntimeError(
                    f"cloudflare is throttling key rotation — {left}s of park left; "
                    f"the tunnel is still on a live /64")
            say("   burning the device instead")

        parked = api_park_left()
        if parked > 15:
            raise RuntimeError(
                f"cloudflare is throttling registrations — {parked}s of park left; "
                f"the tunnel is still on a live /64")

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
        # keep the measured egress from above; only re-read if we never had one
        old_bucket = old_bucket or st.get("egress_prefix") or ""
        if old_bucket:
            burned.add(old_bucket)

        accepted, last_err = None, ""
        attempts = 14          # per wall turn; across turns there is no limit
        burned_hits = 0
        tried = {old_bucket} if old_bucket else set()
        started = time.time()
        for attempt in range(1, attempts + 1):
            if time.time() - started > 300:
                last_err = last_err or "rotation ran past its time budget"
                break
            if not gui_was_up:
                # first burn of this turn: the registration is about to vanish,
                # which is the one moment that leaves the page stuck on the
                # login dialog. one graceful quit, reopened only onto a tunnel
                # that already works.
                gui_was_up = pause_gui(need_outage=True)
            say(f"-- rotation attempt {attempt}/{attempts} --")

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
                    # Cloudflare throttles registration creation. Every rotator
                    # on the box used to rediscover that alone, 14 times a turn;
                    # the park stamp makes one process' throttle teach the rest,
                    # so a single API blip costs seconds, not forty minutes.
                    wait = min(45, 5 * (2 ** (attempt - 1)))
                    park_api(wait + 10, "registration new")
                    log_throttled(GUARD_LOG, "api-busy",
                                  f"warp api busy — parked {wait}s", every=30)
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
            # Measurement decides, and only measurement. The probe retries and
            # corroborates internally; a *failed* reading is "not measured" and
            # goes round again, never the utun leg dressed up as a bucket.
            m = measure_egress(after_addr, force=True) if after_addr else {}
            if m.get("unstable"):
                time.sleep(1.5)
                m = measure_egress(after_addr, force=True)
            egress = m.get("ip") or None
            key = m.get("prefix") or ""
            say(f"   -> bucket {key or 'unmeasured'}"
                f"  ({'+'.join(m.get('sources') or ['none'])},"
                f" warp={m.get('warp') or '?'})  (old {old_bucket or '?'})")

            if not key:
                last_err = "no cloudflare egress after rotation"
                time.sleep(3)
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
                        # the recycle is the whole point of this branch: a block
                        # that just left the burn list must be acceptable again,
                        # so it cannot be sitting in `tried` from the attempts
                        # that burned it. forgetting both lists is what lets the
                        # rescue actually land instead of reporting it pinned.
                        tried = set(burned) | ({old_bucket} if old_bucket else set())
                        log(GUARD_LOG, f"recycled blacklist to {len(keep)} newest blocks")
                        say(f"   pool saturated — recycled burn list to {len(keep)} blocks")
                time.sleep(min(WALL_BACKOFF_MAX, 2 * attempt))
                continue
            # a key only counts as "tried" once it is a candidate we would
            # accept. adding it before the burn check made every burned block
            # permanent for the rest of the turn, so the recycled list above
            # could never hand one back.
            if key in tried:
                last_err = f"same bucket ({key}) — cloudflare pinned it"
                say("   same /64 handed back — rotating again")
                continue
            tried.add(key)

            accepted = (key, after_addr, after_pfx, egress, registration_id())
            break

        if not accepted:
            st["collisions"] = st.get("collisions", 0) + 1
            st["last_hop"] = now()
            jsave(GUARD_STATE, st)
            raise RuntimeError(last_err or "no fresh /64 after retries")

        LAST_MODE["mode"] = "burn"
        key, after_addr, after_pfx, egress, did = accepted
        _OVERLAY_DEV.update(id=did, ts=time.time())
        st.update({"last_hop": now(), "hops": st.get("hops", 0) + 1,
                   "prefix": after_pfx, "addr": after_addr,
                   "egress": egress, "egress_prefix": key,
                   "egress_seen": int(time.time()), "collisions": 0})
        jsave(GUARD_STATE, st)
        drop_caches()
        record_wall("rotated", f"egress {key} (device {before_pfx} -> {after_pfx})")
        overlay_rotate(old_bucket, key, did)
        publish_overlay_state("rotate")
        say(f"bucket {key}  tunnel {after_pfx or '(down)'}  device {did[:8]}…")
        return True, before_pfx, after_pfx
    finally:
        release_gui_hold(gui_hold, gui_was_up)
        # a user hop always leaves the window open and in front. a guard
        # rotation only puts back the window it found closed.
        resume_gui(want_gui)
        if paused:
            resume_keeper()
        if foreign:
            release_foreign_rotlock()
        clear_rotation_phase()
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
        # Never refuse a lane the user asked for. The tunnel is down here for
        # three ordinary reasons — a rotation is mid-surgery, the daemon died,
        # or the registration is stale — and every one of them is repairable in
        # a few seconds. The old path printed "refusing to launch (fail-closed)"
        # on a two-second blip, which is what turned a rotation into a dead
        # terminal and a HUD frozen on the previous /64.
        log(LANE_LOG, "warp down at launch — repairing before opening the lane")
        try:
            heal_tunnel()
        except Exception as exc:
            log(LANE_LOG, f"launch repair failed: {exc}")
        src = iface_v6()
        if not warp_connected() or not src:
            # one last, fuller attempt: a fresh registration rather than a
            # reconnect. this is the same path the guard takes on a wall.
            try:
                rotate(verbose=False)
            except RotationBusy:
                log(LANE_LOG, "launch repair deferred: a rotation already owns warp-cli")
                deadline = time.time() + 30
                while time.time() < deadline and not (warp_connected() and iface_v6(force=True)):
                    time.sleep(2)
            except Exception as exc:
                log(LANE_LOG, f"launch rotation failed: {exc}")
            src = iface_v6()
    if not warp_connected() or not src:
        # genuinely unreachable. stay closed so nothing leaks, but say what to
        # run and leave the HUD message honest instead of pretending success.
        print("ocul: WARP tunnel could not be repaired — lane closed (no leak).", file=sys.stderr)
        print("      ocul doctor   ·   warp-cli connect   ·   ocul hop", file=sys.stderr)
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


def publish_overlay_state(reason="tick", health=None):
    """Write ocul's live truth into the files the HUD already reads.

    Everything comes out of local state — no probe, no DNS, no trace — because
    this runs on the guard tick. Returns the two dicts written, or None when the
    sync is off or the HUD is not installed.
    """
    if not OVERLAY_SYNC or not OVERLAY_GUARD.is_dir():
        return None

    port = int(os.environ.get("OCUL_PORT", 40123))
    # one health socket per tick, shared with the brain — the HUD and the brain
    # asking the same listener twice in the same second is pure waste
    health = proxy_health(port) if health is None else health
    live = bool(health) and health.get("proto") == PROTO
    st = jload(GUARD_STATE, {})
    egress = st.get("egress") or ""
    pfx = st.get("egress_prefix") or (prefix64(egress) if ":" in egress else "")
    est = jload(EDGE_STATE, {})
    edge = est.get("edge") or ""
    # an edge pinned long ago is not this session's edge; printing it as the
    # "current" path would claim a route the proxy is not actually using. drop
    # it once it is clearly stale so the HUD shows "-> /64" instead of a lie.
    try:
        if now() - float(est.get("ts") or 0) > max(EDGE_CACHE_TTL * 4, 600):
            edge = ""
    except Exception:
        edge = ""
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
    # Heartbeat, not a diff. The HUD has to be able to tell "live" from
    # "fossil": a proxy-state.json with an old `ts` is a mux that died, and the
    # panel must show that instead of rendering yesterday's numbers as current.
    # Writing one small file per tick is the cheapest way to keep that honest.
    px["age"] = 0
    px["stale"] = False
    px["source"] = "ocul"
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
    try:
        last_hb = float(ov.get("ocul_ts") or 0)
    except Exception:
        last_hb = 0.0
    ov["ocul_ts"] = now()
    ov_after = {k: v for k, v in ov.items() if k != "ocul_ts"}
    # Write on change, and at least every 30s even when nothing moved. A healthy
    # idle guard and a wedged guard otherwise write byte-identical files, and
    # status.sh had no way to tell "nothing to report" from "nothing is running"
    # — the HUD happily painted a dead rotator as green.
    if ov_before != ov_after or (now() - last_hb) >= 30:
        jsave(OVERLAY_STATE, ov)

    # mirror into the legacy App Support state so status.sh / doctor.sh / the
    # `ouc` CLI read the same truth instead of a file that stopped updating
    # when the old engine was retired.
    if LEGACY_STATE.parent.is_dir():
        ls = jload(LEGACY_STATE, {}) or {}
        if pfx:
            ls["current_64"] = pfx
        if egress:
            ls["egress"] = egress
        ls["hops"] = max(int(ls.get("hops") or 0), int(st.get("hops") or 0))
        ls["last_hop"] = float(st.get("last_hop") or time.time())
        ls["guard_ts"] = time.time()
        jsave(LEGACY_STATE, ls)
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


# the addresses the WARP client itself holds (utun / the edge leg). they are
# infrastructure we connect *to*, not exits a far end ever sees, so they must
# never enter the quota bookkeeping.
WARP_STATE_PREFIXES = ("2606:4700:110:", "2606:4700:100:", "2606:4700::")


def is_egress_bucket(pfx):
    """True when pfx could be an egress /64 someone is counted against."""
    if not pfx or pfx.count(":") < 3:
        return False
    return not pfx.startswith(WARP_STATE_PREFIXES)


def overlay_rotate(burned_pfx, fresh_pfx, device=""):
    """HUD bookkeeping for one real rotation: burn the old /64, credit the new,
    and move the counter the tile shows."""
    if not OVERLAY_SYNC or not OVERLAY_GUARD.is_dir():
        return
    ov = jload(OVERLAY_STATE, {}) or {}
    bl = [x for x in (ov.get("blacklist") or []) if x]
    if burned_pfx and not is_egress_bucket(burned_pfx):
        # 2606:4700:110:… is the utun leg. burning it taught the recycler to
        # hand back blocks we were never on, and hid a real collision.
        log_throttled(GUARD_LOG, "bad-bucket",
                      f"refusing to burn {burned_pfx} — not an egress block",
                      every=600)
        burned_pfx = ""
    if fresh_pfx and not is_egress_bucket(fresh_pfx):
        log_throttled(GUARD_LOG, "bad-bucket",
                      f"refusing to credit {fresh_pfx} — not an egress block",
                      every=600)
        fresh_pfx = ""
    if burned_pfx and burned_pfx not in bl:
        bl.append(burned_pfx)
    # a bucket resets roughly daily, so the oldest entries are the least likely
    # to still be burnt. cap the list instead of letting it grow for weeks: an
    # unbounded burn list makes the next real rotation reject healthy blocks.
    if len(bl) > BLACKLIST_CAP:
        bl = bl[-BLACKLIST_CAP:]
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
    """Record the /64 the far end actually sees, whenever it really changes.

    WARP hands back a different exit on a plain reconnect, not only on a burn, so
    the quota key moves by itself. Two rules keep that honest:

    - never sample while any rotator holds the shared lock. mid-hop the tunnel is
      being re-keyed and a reading taken then is a coin flip between the block we
      left and the block arriving — which is exactly how `egress moved … without
      a rotation` was being logged for the guard's own noise.
    - one reading is a claim, two is a fact. a single sample only arms a
      confirmation; the second agreeing sample records the move. drift that
      resolves itself before the next tick was never drift.
    """
    if rotation_in_progress():
        return None
    src = iface_v6(force=True)
    if not src:
        return None
    m = measure_egress(src, force=True)
    pfx = m.get("prefix") or ""
    if not pfx or m.get("unstable"):
        return None
    st = jload(GUARD_STATE, {})
    cur = st.get("egress_prefix") or ""
    if pfx == cur:
        _DRIFT.update(pfx="", n=0)
        return pfx
    if _DRIFT["pfx"] == pfx:
        _DRIFT["n"] += 1
    else:
        _DRIFT.update(pfx=pfx, n=1)
    if _DRIFT["n"] < 2:
        log_throttled(GUARD_LOG, "egress-arm",
                      f"egress reads {pfx} (state {cur or 'none'}) — confirming",
                      every=300)
        return cur or None
    _DRIFT.update(pfx="", n=0)
    st.update({"egress": m.get("ip") or "", "egress_prefix": pfx,
               "egress_seen": now(), "egress_warp": m.get("warp") or ""})
    save_if_changed(GUARD_STATE, st)
    srcs = "+".join(m.get("sources") or []) or "?"
    log(GUARD_LOG, f"egress moved {cur or '(none)'} -> {pfx}"
                   f"  ({srcs}, warp={m.get('warp') or '?'})")
    record_wall("egress-drift", f"{cur} -> {pfx}")
    publish_overlay_state("egress")
    t = time.time()
    ev = [x for x in (_DRIFT.get("events") or []) if t - x < 600] + [t]
    _DRIFT["events"] = ev
    if len(ev) >= 3:
        _DRIFT["events"] = []
        if not warp_connected():
            log(GUARD_LOG, "egress flapping on a dead tunnel — healing")
            heal_tunnel()
        else:
            log_throttled(GUARD_LOG, "egress-flap",
                          f"egress re-pinned {len(ev)}x in 10m — tunnel healthy, "
                          f"leaving it alone", every=600)
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
    if heal_login(force=True):
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


# ---- the brain ------------------------------------------------------------
# One file, one writer, many readers.
#
# Every consumer used to re-derive the same facts from four state files plus a
# handful of `warp-cli` and `launchctl` calls — which is why the HUD needed a
# 641-line shell script and two sudo calls per two-second refresh just to know
# whether the tunnel was up. The guard already holds all of it. So the guard
# writes it once, atomically, and everybody else reads.
#
# `beat` moves on every write, even when nothing changed, so a reader can tell
# "idle" from "wedged" by looking at one number instead of waiting for a stamp
# to age. `seq` moves only when the content actually changed, so a reader that
# re-renders can skip the repaint.
#
# Three workers, three failure modes, no shared blocking:
#   guard   6s   tail the wall log, own the rotate lock      (wedged tail)
#   sensor  20s  measure the exit and DNS                   (slow network)
#   rotator  on  rotate, publish its phase here             (API throttle)
# The sensor is a thread, not a process: it shares the measurement cache with
# the guard, and file-based IPC for a 20-second probe would cost more than the
# probe does.

BRAIN_SCHEMA = 1
BRAIN_FRESH = 20        # seconds a reader may trust `beat`
SENSOR_EVERY = 20       # seconds between sensor sweeps
_BRAIN_LOCK = threading.Lock()
_KEEPER = {"ok": False, "ts": 0.0}
_WARP_MODE = {"mode": "", "ts": 0.0}


def brain_path():
    return (OVERLAY_GUARD / "brain.json") if OVERLAY_GUARD.is_dir() \
        else STATE / "brain.json"


def brain_read():
    b = jload(brain_path(), None)
    return b if isinstance(b, dict) else {}


def brain_age(b=None):
    b = brain_read() if b is None else b
    try:
        return max(0, now() - int(b.get("beat") or 0))
    except Exception:
        return 10 ** 6


def brain_update(**sections):
    """Merge sections into the brain atomically.

    Section dicts merge key-by-key so a caller can publish `egress` without
    clobbering `proxy`. Everything else replaces. The write is an atomic rename
    via jsave, so a reader never sees half a document.
    """
    with _BRAIN_LOCK:
        b = brain_read()
        if b.get("v") != BRAIN_SCHEMA:
            b = {"v": BRAIN_SCHEMA, "seq": 0}
        changed = False
        for k, v in sections.items():
            if isinstance(v, dict) and isinstance(b.get(k), dict):
                merged = dict(b[k])
                merged.update(v)
                if merged != b[k]:
                    b[k] = merged
                    changed = True
            elif b.get(k) != v:
                b[k] = v
                changed = True
        if changed:
            b["seq"] = int(b.get("seq") or 0) + 1
        b["beat"] = now()
        b["ts"] = now()
        jsave(brain_path(), b)
        return b


def warp_mode(ttl=60.0):
    """The client's operating mode (`TunnelOnly`, `warp`, `doh`, …).

    One `warp-cli settings` call a minute instead of one per UI refresh: the
    value changes when a human changes it, which is roughly never."""
    if _WARP_MODE["mode"] and time.time() - _WARP_MODE["ts"] < ttl:
        return _WARP_MODE["mode"]
    rc, out, _ = run([WARP, "--accept-tos", "settings"], timeout=8)
    if rc != 0:
        return _WARP_MODE["mode"]
    mode = ""
    for ln in out.splitlines():
        if "Mode:" in ln:
            mode = ln.split("Mode:", 1)[1].strip()
            break
    if mode:
        _WARP_MODE.update(mode=mode, ts=time.time())
    return mode


def keeper_running(ttl=30.0):
    """Is the keeper agent loaded? launchctl is a fork, and the answer changes
    only on install or removal — so ask at most every 30s, not every tick."""
    if time.time() - _KEEPER["ts"] < ttl:
        return _KEEPER["ok"]
    uid = os.getuid()
    ok = False
    for label in ("com.ouc.keeper", "com.opencode-unlimited.keeper"):
        for domain in (f"gui/{uid}", "system"):
            rc, _, _ = run(["launchctl", "print", f"{domain}/{label}"], timeout=3)
            if rc == 0:
                ok = True
                break
        if ok:
            break
    _KEEPER.update(ok=ok, ts=time.time())
    return ok


def advise(b):
    """Read the document and say what it means. Pure: no probe, no clock skew.

    This is the part that makes it a brain rather than a status file. Every
    consumer used to re-derive the same interpretation — is the guard alive, is
    the rotation legitimate, is the proxy actually serving — and each did it
    slightly differently, which is how the HUD once painted a hung guard green.
    """
    score, advice = 100, []
    w = b.get("warp") or {}
    px = b.get("proxy") or {}
    rot = b.get("rotation") or {}
    eg = b.get("egress") or {}
    park = b.get("park") or {}
    ident = b.get("identity") or {}
    sens = b.get("sensors") or {}

    def hit(code, level, text, cost):
        nonlocal score
        score -= cost
        advice.append({"code": code, "level": level, "text": text})

    age = brain_age(b)
    if age > BRAIN_FRESH:
        hit("stale", "bad",
            f"guard has not written for {age}s — it is wedged or stopped", 60)
    if not w.get("connected") and not rot.get("active"):
        hit("tunnel-down", "bad",
            "tunnel is down and nothing is rotating — the healer will reconnect", 35)
    if rot.get("active"):
        try:
            sat = max(0, now() - int(rot.get("since") or now()))
        except Exception:
            sat = 0
        hit("rotating", "info",
            f"rotation in progress: {rot.get('phase') or 'starting'}"
            f" (attempt {rot.get('attempt') or 0}/{rot.get('max') or 14},"
            f" {sat}s) — do not click HOP", 0)
    if int(park.get("left") or 0) > 0:
        hit("parked", "warn",
            f"Cloudflare throttled the API — rotations parked {park['left']}s", 10)
    if eg.get("unstable"):
        hit("egress-unstable", "warn",
            "the exit moved while measuring — the reading is being retaken", 8)
    if not eg.get("prefix"):
        hit("egress-unknown", "warn",
            "no measured exit — the quota key is unknown right now", 15)
    if ident.get("burnt"):
        hit("burnt", "warn",
            "the current /64 is already on the blacklist", 10)
    if not px.get("up"):
        hit("proxy-down", "bad",
            "the lane proxy is not listening — the guard will restart it", 30)
    if int(px.get("refused") or 0) > 200:
        hit("proxy-refused", "warn",
            f"{px['refused']} refused connections — something upstream is unhappy", 5)
    if sens.get("dns") is False:
        hit("dns", "warn",
            "name resolution through the tunnel is failing", 12)
    if (b.get("guard") or {}).get("pending"):
        hit("wall-pending", "warn",
            "a wall was hit while rotations were parked — it retries on its own", 8)

    score = max(0, min(100, score))
    state = "ok" if score >= 90 else ("warn" if score >= 60 else "bad")
    return {"score": score, "state": state}, advice


def brain_publish(health=None, reason="tick"):
    """Assemble the machine's truth from local state and write it once.

    Cheap on purpose: no probe, no subprocess beyond the proxy health socket the
    caller already paid for. Everything expensive lives in the sensor thread,
    which is exactly why a slow network can no longer delay wall detection.
    """
    port = int(os.environ.get("OCUL_PORT", 40123))
    health = proxy_health(port) if health is None else health
    live = bool(health) and health.get("proto") == PROTO
    st = jload(GUARD_STATE, {}) or {}
    est = jload(EDGE_STATE, {}) or {}
    ov = jload(OVERLAY_STATE, {}) or {}
    rot = rotation_phase()
    cached = _EGRESS_CACHE.get("info") or {}

    # the sensor's reading is fresher than guard.json and lives in this process;
    # prefer it, and fall back to the last recorded one when it has never run.
    eg_ip = cached.get("ip") or st.get("egress") or ""
    eg_pfx = cached.get("prefix") or st.get("egress_prefix") \
        or (prefix64(eg_ip) if ":" in eg_ip else "")
    try:
        eg_at = float(cached.get("ts") or st.get("egress_seen") or 0)
    except Exception:
        eg_at = 0.0

    edge = est.get("edge") or ""
    try:
        if now() - float(est.get("ts") or 0) > max(EDGE_CACHE_TTL * 4, 600):
            edge = ""
    except Exception:
        edge = ""

    device = overlay_device() or ""
    bl = [x for x in (ov.get("blacklist") or []) if x]
    src6 = iface_v6() or ""

    sections = {
        "writer": {"pid": os.getpid(), "kind": "guard", "reason": reason},
        # merge semantics: omitting `mode` keeps the last one the sensor
        # learned, so a tick never blanks a known mode into "?".
        "warp": dict({"connected": warp_connected()},
                     **({"mode": warp_mode()} if warp_mode() else {})),
        "guard": {"running": True, "pid": os.getpid(), "tick": TICK,
                  "pending": bool(st.get("pending_wall"))},
        "keeper": {"running": keeper_running()},
        "egress": {"ip": eg_ip, "prefix": eg_pfx, "at": int(eg_at),
                   "colo": cached.get("colo") or "",
                   "warp": cached.get("warp") or "",
                   "loc": cached.get("loc") or "",
                   "sources": cached.get("sources") or [],
                   "unstable": bool(cached.get("unstable")),
                   "ms": int(cached.get("ms") or 0)},
        "tunnel": {"src6": src6, "prefix": prefix64(src6) if src6 else "",
                   "edge": edge, "device": device},
        "proxy": {"up": live, "pid": int(health.get("pid") or 0) if live else 0,
                  "listen": f"127.0.0.1:{port}", "proto": PROTO,
                  "active": int(health.get("active") or 0) if live else 0,
                  "total": int(health.get("total") or 0) if live else 0,
                  "errors": int(health.get("errors") or 0) if live else 0,
                  "refused": int(health.get("refused") or 0) if live else 0},
        "rotation": {"active": bool(rot), "phase": rot.get("phase") or "",
                     "pid": int(rot.get("pid") or 0),
                     "since": int(rot.get("started") or 0),
                     "attempt": int(rot.get("attempt") or 0),
                     "max": int(rot.get("max") or 14),
                     "mode": LAST_MODE["mode"] or ""},
        "park": {"left": api_park_left(),
                 "until": int(st.get("api_busy_until") or 0)},
        "identity": {"prefix": eg_pfx, "seen6": eg_ip,
                     "device": (device or "")[:8],
                     "hops": int(st.get("hops") or 0),
                     "collisions": int(st.get("collisions") or 0),
                     "blacklist": len(bl),
                     "burnt": bool(eg_pfx and eg_pfx in bl)},
    }
    view = dict(brain_read())
    for k, v in sections.items():
        if isinstance(v, dict) and isinstance(view.get(k), dict):
            merged = dict(view[k])
            merged.update(v)
            view[k] = merged
        else:
            view[k] = v
    health_doc, advice = advise(view)
    sections["health"] = health_doc
    sections["advice"] = advice
    return brain_update(**sections)


def sensor_tick(force=False):
    """Measure what only a probe can tell: the exit, and whether DNS answers.

    Never during a rotation. Mid-hop the tunnel is between two exits on purpose
    and a reading taken then is a coin flip — the exact condition that used to
    write `egress moved … without a rotation` for the guard's own working hop.
    """
    if rotation_in_progress():
        return {}
    src = iface_v6(force=True)
    if not src:
        return {}
    m = measure_egress(src, force=force)
    if not m.get("prefix"):
        # one dead probe is a bad minute, not a verdict: retry once before
        # telling the brain there is no exit at all
        time.sleep(1.5)
        m = measure_egress(src, force=True)
    rc, out, _ = run(["dig", "+short", "+time=2", "+tries=1", "opencode.ai"],
                     timeout=4)
    dns = None if rc == 127 else bool(out.strip())
    data = {"dns": dns, "at": now(), "src": src,
            "ok": bool(m.get("prefix")),
            "ms": int(m.get("ms") or 0)}
    brain_update(sensors=data)
    return data


def sensor_loop():
    """The slow loop. Owns every network probe so the guard tick never blocks."""
    time.sleep(3)
    while True:
        try:
            sensor_tick()
        except Exception as exc:
            log_throttled(GUARD_LOG, "sensor", f"sensor error: {exc!r}", every=300)
        time.sleep(SENSOR_EVERY)


def cmd_brain(args=None):
    """`ocul brain` — the whole document, or the one paragraph that matters."""
    b = brain_read()
    if getattr(args, "json", False):
        print(json.dumps(b, indent=2, sort_keys=True))
        return 0
    if not b:
        print("brain    not written yet — is the guard running?")
        return 1
    age = brain_age(b)
    h = b.get("health") or {}
    eg = b.get("egress") or {}
    tr = b.get("tunnel") or {}
    px = b.get("proxy") or {}
    rot = b.get("rotation") or {}
    w = b.get("warp") or {}
    print(f"brain    seq {b.get('seq')}  beat {age}s ago  "
          + ("LIVE" if age <= BRAIN_FRESH else "STALE"))
    print(f"health   {h.get('score')}  {h.get('state')}")
    print(f"warp     {'connected' if w.get('connected') else 'down'}"
          f"  mode {w.get('mode') or '?'}")
    print(f"egress   {eg.get('prefix') or 'unknown'}"
          f"  {eg.get('ip') or ''}".rstrip())
    print(f"tunnel   {tr.get('prefix') or 'none'}  edge {tr.get('edge') or 'unset'}")
    print(f"proxy    {'up' if px.get('up') else 'down'}  {px.get('listen') or ''}"
          + (f"  {px.get('active')}/{px.get('total')}" if px.get("up") else ""))
    print(f"rotation " + (f"in progress — {rot.get('phase') or 'starting'}"
                         if rot.get("active") else "idle"))
    for a in b.get("advice") or []:
        print(f"  [{a.get('level')}] {a.get('text')}")
    return 0


def on_wall(session_ids=None):
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
    wall_sids = [x for x in (session_ids or []) if x]
    if wall_sids and all(_resume_burst(x) >= 4 for x in wall_sids):
        # this chat already got four new addresses in a quarter hour and the
        # wall is still there: the quota is on the account, not the exit. A
        # rotation now buys nothing and costs API headroom for the walls that
        # are address-shaped. Self-clearing, so "infinite" is never turned off.
        log_throttled(GUARD_LOG, "account-wall",
                      "wall survived 4 fresh /64s — account-side limit, not rotating",
                      every=600)
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
        st.pop("pending_wall", None)
        jsave(GUARD_STATE, st)
        log(GUARD_LOG, f"wall rotated {before} -> {after} moved={moved}")
        # the rotation was never the point on its own: the turn is dead and the
        # user had to retype. put the message back into every chat it cut off.
        sent = dispatch_resume(session_ids)
        if sent:
            notify("ocul", f"new /64 {after or 'unknown'} — resumed {sent} chat(s)")
        else:
            notify("ocul", f"new /64 {after or 'unknown'} — resend the message")
    except RotationBusy:
        log_throttled(GUARD_LOG, "busy", "wall: rotation already in progress", every=60)
    except Exception as exc:
        if "throttling" in str(exc):
            # The wall is real and the chats it cut off are still dead. Parking
            # the API does not cancel the wall, so remember it and come back the
            # moment the park lifts — otherwise one throttled minute becomes a
            # dead chat until the user notices.
            st2 = jload(GUARD_STATE, {})
            prev = st2.get("pending_wall") or {}
            st2["pending_wall"] = {
                "ts": int(prev.get("ts") or t),
                "sessions": sorted(set((prev.get("sessions") or []) +
                                       [x for x in (session_ids or []) if x])),
                "tries": int(prev.get("tries") or 0) + 1,
                "next_try": int(t) + 15,
            }
            jsave(GUARD_STATE, st2)
            log_throttled(GUARD_LOG, "wall-throttle", f"wall: {exc}", every=120)
            return
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


RESUME_LOG = STATE / "resume.log"
RESUME_STATE = STATE / "resume.json"


def _oc_bin():
    return os.environ.get("OCUL_OC_BIN") or shutil.which("opencode") or ""


def _resume_recent(sid):
    st = jload(RESUME_STATE, {}) or {}
    return time.time() - float(st.get(sid, 0) or 0) < 60


RESUME_COUNT = STATE / "resume.count.json"


def _resume_burst(sid, window=900):
    """How many times this chat has been resumed in the last `window` seconds."""
    st = jload(RESUME_COUNT, {}) or {}
    cutoff = time.time() - window
    return len([t for t in (st.get(sid) or []) if t > cutoff])


def _resume_bump(sid):
    st = jload(RESUME_COUNT, {}) or {}
    cutoff = time.time() - 86400
    for k in list(st):
        st[k] = [t for t in st[k] if t > cutoff]
        if not st[k]:
            st.pop(k, None)
    st.setdefault(sid, []).append(int(time.time()))
    if len(st) > 200:
        st = dict(sorted(st.items(), key=lambda kv: kv[1][-1])[-100:])
    jsave(RESUME_COUNT, st)


def _resume_stamp(sid):
    st = jload(RESUME_STATE, {}) or {}
    st[sid] = int(time.time())
    if len(st) > 200:
        st = dict(sorted(st.items(), key=lambda kv: kv[1])[-100:])
    jsave(RESUME_STATE, st)


def session_from_line(line):
    m = re.search(r"sessionID=(ses_[A-Za-z0-9]+)", line or "")
    return m.group(1) if m else ""


def _spawn_resume(argv, delay=0.0):
    """Detach one `opencode run` per chat. Never blocks, never retries.

    A rotation finishes while the guard tick is still running; poking the chat
    straight away sometimes lands before the edge has finished moving the /64.
    A few seconds of quiet fixes that, and a daemon thread keeps the wait off
    the tick entirely.
    """
    def _go():
        try:
            if delay > 0:
                time.sleep(delay)
            # the log is the transcript of every resumed run; cap it so a
            # session that keeps talking cannot fill the state dir
            try:
                if RESUME_LOG.exists() and RESUME_LOG.stat().st_size > 4 * 1024 * 1024:
                    RESUME_LOG.rename(RESUME_LOG.with_suffix(".log.1"))
            except OSError:
                pass
            fh = open(RESUME_LOG, "ab")
            subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=fh, stderr=fh,
                             start_new_session=True, cwd=str(Path.home()))
            fh.close()
        except Exception as exc:
            log(GUARD_LOG, f"resume spawn failed: {exc}")
    threading.Thread(target=_go, name="resume", daemon=True).start()


def dispatch_resume(session_ids):
    """Send 'continue' into the chats a wall cut off, through the lane.

    A rotation on its own does not resume anything — the turn is dead and the
    user has to retype. `opencode run --session <id> continue` talks to the
    same background service the TUI uses, so the chat picks up where it stopped
    on the new /64. One message per session per minute; never a retry loop.
    """
    if os.environ.get("OCUL_RESUME", "1") == "0":
        return 0
    msg = os.environ.get("OCUL_RESUME_MSG") or "continue"
    oc = _oc_bin()
    if not oc:
        log_throttled(GUARD_LOG, "resume-no-oc",
                      "resume skipped: opencode is not on PATH", every=600)
        return 0
    sent = 0
    for sid in list(dict.fromkeys(s for s in (session_ids or []) if s)) or [""]:
        if sid and _resume_recent(sid):
            continue
        if sid and _resume_burst(sid) >= 4:
            # four fresh addresses in fifteen minutes and the chat still hit the
            # wall. That limit is following the account, not the exit, so more
            # rotation only spends the WARP API for nothing. It clears itself.
            log_throttled(GUARD_LOG, "resume-cap",
                          f"{sid[:14]}… hit the wall on 4 fresh /64s in 15m — "
                          f"holding resumes for this chat", every=900)
            continue
        argv = [oc, "run"]
        argv += ["--session", sid] if sid else ["--continue"]
        if os.environ.get("OCUL_RESUME_AUTO", "1") == "1":
            argv.append("--auto")
        argv.append(msg)
        if os.environ.get("OCUL_RESUME_DRY") == "1":
            log(GUARD_LOG, "resume dry-run: " + " ".join(argv))
            sent += 1
            continue
        try:
            ensure_dirs()
            _resume_stamp(sid or "-")
            if sid:
                _resume_bump(sid)
            delay = float(os.environ.get("OCUL_RESUME_DELAY", "4") or 0)
            _spawn_resume(argv, delay)
            sent += 1
            log(GUARD_LOG,
                "resume queued for " + (sid[:14] + "…" if sid else "the latest chat")
                + (f" in {delay:g}s" if delay > 0 else ""))
        except Exception as exc:
            log(GUARD_LOG, f"resume failed: {exc}")
    return sent


def matched_line(chunk):
    text = chunk.decode("utf-8", "replace")
    for line in text.splitlines():
        if WALL_RE.search(line):
            return line.strip()[:200]
    return ""


def matched_walls(chunk):
    """Every wall line in the chunk, with the session it cut off.

    A burst usually arrives together (one per retrying turn), and resuming only
    the first leaves the other chats dead until the user notices.
    """
    out = []
    text = chunk.decode("utf-8", "replace")
    for line in text.splitlines():
        if WALL_RE.search(line):
            out.append((line.strip(), session_from_line(line)))
    return out


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
        brain_publish(reason="guard-up")
        # the sensor owns every network probe. a separate thread on purpose: a
        # dead network can cost the sensor nine seconds and the wall detector
        # will not notice, because it never asked the network anything.
        threading.Thread(target=sensor_loop, name="sensor", daemon=True).start()

        ticks = 0
        while True:
            ticks += 1
            try:
                offset, chunk = pump_log(OPENCODE_LOG, offset)
                walls = matched_walls(chunk) if chunk else []
                if walls:
                    for line, _sid in walls:
                        record_wall("detected", line)
                    on_wall([sid for _line, sid in walls])

                st = jload(GUARD_STATE, {})
                st["offset"] = offset
                st["guard_pid"] = os.getpid()
                # one write per change, not one write per tick: 14k small writes a
                # day on the same values is how guard.json ends up half-flushed
                save_if_changed(GUARD_STATE, st)

                pend = jload(GUARD_STATE, {}).get("pending_wall") or {}
                if pend and api_park_left() <= 0 \
                        and now() >= int(pend.get("next_try") or 0) \
                        and now() - int(pend.get("ts") or 0) < 1800:
                    log(GUARD_LOG,
                        f"pending wall retry ({now() - int(pend.get('ts') or 0)}s old, "
                        f"{pend.get('tries') or 0} parked tries)")
                    on_wall(pend.get("sessions") or [])

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
                h = proxy_health(port)
                publish_overlay_state("tick", health=h)
                brain_publish(health=h, reason="tick")
            except Exception as exc:
                log(GUARD_LOG, f"tick error: {exc!r}")
            time.sleep(TICK)
    finally:
        lock.release()


def cmd_resume(args):
    """Push 'continue' into a chat by hand, the same way a wall does.

    Useful after a rotation that happened while nobody was watching, and the
    honest way to test the resume path without waiting for a real wall:
    `ocul resume` takes the latest chat, `ocul resume ses_…` a specific one.
    """
    if os.environ.get("OCUL_RESUME_DRY") == "1":
        print("dry run — nothing is sent")
    sid = (getattr(args, "session", "") or "").strip()
    sent = dispatch_resume([sid] if sid else [])
    if not sent:
        print("nothing queued — chat resumed too recently, hit the resume cap, "
              "or opencode is not on PATH")
        return 1
    print(f"queued: continue -> {sid[:16] + '…' if sid else 'the latest chat'}")
    print(f"log    {RESUME_LOG}")
    return 0


def cmd_where():
    """Read-only: what /64 are we on, how sure are we, is the tunnel alive.

    The HUD's WHERE chip runs the hop script with --where. It used to be
    swallowed by the hop, so asking "where am I" quietly spent an egress; it then
    answered with the utun leg whenever the trace failed. Now it takes no lock,
    writes no state, rotates nothing, and prints *how* the address was measured —
    `trace`, `echo`, or both — because a bucket nobody can corroborate is not an
    answer.
    """
    st = jload(GUARD_STATE, {})
    last = st.get("egress_prefix") or ""
    addr = iface_v6(force=True)
    m = measure_egress(addr, force=True) if addr else {}
    seen = m.get("ip") or ""
    bucket = m.get("prefix") or ""
    stale = False
    if not bucket and last:
        bucket, stale = last, True
    bl = (jload(OVERLAY_STATE, {}) or {}).get("blacklist") or []
    srcs = "+".join(m.get("sources") or []) or "none"
    note = ""
    if stale:
        note = "  (last measured — egress not reachable right now)"
    elif m.get("unstable"):
        note = "  (unstable — the exit moved while measuring)"
    print(f"bucket   {bucket or 'unknown'}{note}")
    print(f"v6       {seen or 'none'}")
    print(f"measure  {srcs}"
          + (f"  colo {m.get('colo')}" if m.get("colo") else "")
          + (f"  warp={m.get('warp')}" if m.get("warp") else "")
          + (f"  {m['ms']}ms" if m.get("ms") else ""))
    print(f"tunnel   {st.get('prefix') or prefix64(addr) or 'none'}")
    print(f"device   {registration_id() or 'none'}")
    print(f"warp     {'connected' if warp_connected() else 'down'}")
    print(f"burnt    {'yes' if bucket and bucket in bl else 'no'}")
    if bl:
        print("blacklist")
        for b in bl[-14:]:
            print(f"         {b}")
    return 0


def cmd_hop(args):
    if getattr(args, "where", False):
        return cmd_where()
    wait = float(getattr(args, "wait", 20.0) or 0)
    cheap = not bool(getattr(args, "no_cheap", False))
    started = time.time()
    try:
        moved, before, after = rotate(verbose=True, lock_timeout=wait, cheap_first=cheap)
    except RotationBusy as exc:
        # Not a fault: the guard (or another hop) owns the tunnel and is doing
        # exactly this work. Say what is true and what to do, once.
        st = jload(GUARD_STATE, {})
        live = st.get("egress_prefix") or before_or_none()
        print(f"rotation deferred: {exc}")
        if live:
            print(f"egress  {live}  (still live — the tunnel is up, retry when the turn ends)")
        return 3
    except Exception as exc:
        if "throttling" in str(exc):
            print(f"rotation deferred: {exc}")
            print("tunnel unchanged and up — a wall burns the same API, so retrying now only wastes it")
            return 3
        print(f"rotation failed: {exc}")
        return 2
    src = iface_v6()
    fields = trace_v6(src) if src else {}
    seen = fields.get("ip", "?")
    print(f"exit   {seen}   warp={fields.get('warp','?')} colo={fields.get('colo','?')}")
    print(f"bucket {prefix64(seen) if ':' in seen else prefix64(after)}")
    print("fresh /64" if moved else "same /64 — cloudflare handed back the old block, run it again")
    print(f"took   {time.time() - started:.1f}s  ({LAST_MODE['mode'] or 'rotate'})")
    return 0 if moved else 1


def before_or_none():
    addr = iface_v6()
    return prefix64(addr) if addr else ""


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
    ph = rotation_phase()
    if ph:
        started = ph.get("started") or 0
        age = int(now() - started) if started else 0
        print(f"rotation {ph.get('phase','?')} pid {ph.get('pid','?')} {age}s")
    else:
        print("rotation idle")
    park = api_park_left()
    if park:
        print(f"api park {park}s left (cloudflare throttling registrations)")
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
    p = sub.add_parser("hop", help="burn the device and take a fresh egress /64")
    p.add_argument("--wait", type=float, default=20.0,
                   help="seconds to wait for a peer rotation to finish (default 20)")
    p.add_argument("--no-cheap", action="store_true",
                   help="skip the reconnect pass and burn the registration immediately")
    p.add_argument("--where", "--dry-run", dest="where", action="store_true",
                   help="say what identity we are on and touch nothing at all")
    p = sub.add_parser("resume", help="send 'continue' into a chat (wall resume, by hand)")
    p.add_argument("session", nargs="?", default="", help="session id (ses_…), or latest")
    sub.add_parser("where", help="read-only: what /64 we are on, burnt or not")
    p = sub.add_parser("brain",
                       help="the whole machine in one read: health, advice, phase")
    p.add_argument("--json", action="store_true", help="raw document")
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
    if args.cmd == "where":
        return cmd_where()
    if args.cmd == "brain":
        return cmd_brain(args)
    if args.cmd == "resume":
        return cmd_resume(args)
    if args.cmd == "resume":
        return cmd_resume(args)
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
