#!/usr/bin/env python3
"""proxy-mux — a local CONNECT proxy that rotates a pool of upstreams.

Why a local mux instead of pointing the CLI straight at a proxy: rotation has
to be a decision this project owns. One listener keeps the client config fixed
(127.0.0.1:8899 forever) while the upstream behind it changes per connection,
so a rotation costs no tunnel, no DNS window, and no client restart.

    client ──CONNECT──▶ 127.0.0.1:8899 ──▶ upstream #3 ──▶ target

Rotation policy:
    conn    (default) next upstream on every new connection — maximum IP spread
    window  hold one upstream for OUC_PROXY_WINDOW seconds — fewer IP changes,
            which some consoles treat as less suspicious

Fail-closed by default: if every upstream is dead the proxy answers 502. It
never falls back to the machine's own egress unless OUC_PROXY_ALLOW_DIRECT=1,
because a silent direct fallback is a quota leak wearing a proxy's coat.

Written to be boring: stdlib only, bounded buffers, per-upstream timeouts,
dead upstreams parked for 60s, and a state file the HUD reads.
"""

import asyncio
import base64
import json
import os
import signal
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DEST = os.environ.get("OUC_DEST", os.path.join(HOME, ".local/share/opencode-unlimited"))
GUARD = os.path.join(DEST, "guard")

POOL = os.environ.get("OUC_PROXY_POOL", os.path.join(DEST, "proxies.txt"))
CONF = os.environ.get("OUC_PROXY_CONF", os.path.join(DEST, "proxy.conf"))
STATE = os.path.join(GUARD, "proxy-state.json")
CMD = os.path.join(GUARD, "proxy-cmd")


def read_conf():
    """proxy.conf holds what the sheet changes at runtime.

    It is a file rather than an env var because rotation policy has to survive
    a restart of the mux without the caller remembering the flag, and the HUD
    has to be able to read the same answer the mux is using.
    """
    out = {}
    try:
        with open(CONF, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                out[k.strip().lower()] = v.strip()
    except FileNotFoundError:
        pass
    return out


_CFG = read_conf()
HOST = os.environ.get("OUC_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("OUC_PROXY_PORT", "8899"))
POLICY = os.environ.get("OUC_PROXY_ROTATE", _CFG.get("policy", "conn"))
WINDOW = int(os.environ.get("OUC_PROXY_WINDOW", _CFG.get("window", "300")))
ALLOW_DIRECT = os.environ.get("OUC_PROXY_ALLOW_DIRECT", "0") == "1"

CONNECT_TIMEOUT = 9.0      # one upstream, one try
HEADER_LIMIT = 16384       # a proxy that sends more than this is not a proxy
DEAD_FOR = 60.0            # how long a failed upstream sits out
MAX_TRIES = 4              # upstreams tried per client connection


# --------------------------------------------------------------------- pool
def parse_spec(spec):
    """Accept the four shapes people actually paste.

        host:port:user:pass        (webshare's default export)
        user:pass@host:port
        http://user:pass@host:port
        socks5://user:pass@host:port
    """
    spec = spec.strip()
    scheme = "http"
    if "://" in spec:
        scheme, spec = spec.split("://", 1)
        scheme = scheme.lower()
    if "@" in spec:
        cred, hostport = spec.rsplit("@", 1)
        user, _, pw = cred.partition(":")
    elif spec.count(":") == 3:
        host, port, user, pw = spec.split(":", 3)
        hostport = "%s:%s" % (host, port)
    else:
        user = pw = ""
        hostport = spec
    host, _, port = hostport.rpartition(":")
    if not host or not port.isdigit():
        return None
    return {"scheme": scheme, "host": host, "port": int(port), "user": user, "pass": pw}


def load_pool():
    try:
        with open(POOL, "r", encoding="utf-8", errors="replace") as f:
            lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    except FileNotFoundError:
        return []
    out, seen = [], set()
    for line in lines:
        if line == "direct" and ALLOW_DIRECT:
            out.append({"scheme": "direct", "host": "", "port": 0, "user": "", "pass": ""})
            continue
        p = parse_spec(line)
        if not p:
            continue
        key = (p["scheme"], p["host"], p["port"], p["user"])
        if key in seen:
            continue
        seen.add(key)
        out.append(p)
    return out


def label(p, i):
    if p["scheme"] == "direct":
        return "direct"
    return "%s:%d" % (p["host"], p["port"]) if not p["user"] else "%s@%s:%d" % (
        p["user"][:3] + "…", p["host"], p["port"])


# ------------------------------------------------------------- health seeds
HEALTH = os.path.join(GUARD, "proxy-health.json")
HEALTH_TTL = 900.0   # a verdict older than this is a guess again


def seed_health(pool):
    """park the upstreams the last TEST already found dead.

    without this, a fresh mux starts with every upstream "healthy" and only
    learns the truth one failed connection at a time. the sheet's TEST is the
    probe; this is the mux reading its answer.
    """
    out = {}
    try:
        with open(HEALTH, "r", encoding="utf-8") as f:
            rec = json.load(f)
    except Exception:
        return out
    now = time.time()
    for i, p in enumerate(pool):
        if p["scheme"] == "direct":
            continue
        r = rec.get("%s:%d" % (p["host"], p["port"]))
        if not r or r.get("state") != "dead":
            continue
        age = now - float(r.get("ts") or 0)
        if 0 <= age < HEALTH_TTL:
            out[i] = now + DEAD_FOR
    return out


# -------------------------------------------------------------------- state
def system_flag():
    """whether the machine-wide switch is on, as recorded by proxy-pool sys.

    the mux never touches networksetup; it only reports what the CLI wrote, so
    a crash here can never invent a "system proxy on" that is not there.
    """
    try:
        with open(STATE, "r", encoding="utf-8") as f:
            return bool(json.load(f).get("system"))
    except Exception:
        return False


def restore_system():
    """put the machine-wide proxy back if we are the one holding it down.

    the mux never sets the system proxy; proxy-pool.sh does. but the mux is the
    thing whose death strands every app on a dead port, so the mux is the thing
    that undoes it on the way out. bounded: 15s, no output, no exceptions.
    """
    if not system_flag():
        return
    cli = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proxy-pool.sh")
    if not os.path.exists(cli):
        return
    try:
        subprocess.run(["bash", cli, "sys", "off"], timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


class Mux:
    def __init__(self, pool):
        self.pool = pool
        self.idx = 0
        self.dead = seed_health(pool)   # index -> unix time it may be retried
        self.window_start = 0.0
        self.rotations = 0
        self.served = 0
        self.failed = 0
        self.started = time.time()
        self.persist()

    def apply_conf(self):
        """pick up policy changes from proxy.conf without a restart."""
        global POLICY, WINDOW
        cfg = read_conf()
        if cfg.get("policy") in ("conn", "window"):
            POLICY = cfg["policy"]
        try:
            if cfg.get("window"):
                WINDOW = max(30, int(cfg["window"]))
        except ValueError:
            pass
        self.window_start = 0.0

    def live_indices(self):
        now = time.time()
        return [i for i in range(len(self.pool)) if self.dead.get(i, 0) <= now]

    def pick(self):
        """Next upstream under the current policy, skipping parked ones."""
        live = self.live_indices()
        if not live:
            return None
        if POLICY == "window" and self.window_start and time.time() - self.window_start < WINDOW:
            if self.idx in live:
                return self.idx
        for step in range(len(self.pool)):
            i = (self.idx + step) % len(self.pool)
            if i in live:
                if POLICY == "window":
                    self.window_start = time.time()
                self.idx = i
                return i
        return None

    def rotate(self):
        """Manual/failed rotation: move past the current upstream."""
        if not self.pool:
            return None
        self.idx = (self.idx + 1) % len(self.pool)
        self.rotations += 1
        self.window_start = 0.0
        if POLICY == "window":
            self.window_start = time.time()
        self.persist()
        return self.pick()

    def mark_dead(self, i):
        self.dead[i] = time.time() + DEAD_FOR
        self.failed += 1
        self.persist()

    def persist(self):
        cur = None
        if self.pool and self.idx < len(self.pool):
            cur = label(self.pool[self.idx], self.idx)
        data = {
            "up": True,
            "pid": os.getpid(),
            "listen": "%s:%d" % (HOST, PORT),
            "policy": POLICY,
            "window": WINDOW,
            "system": system_flag(),
            "pool": len(self.pool),
            # health is a claim, so it only counts upstreams the mux has
            # actually tried. a fresh start with a dead pool used to read
            # "2 of 2 healthy" until the first connection failed.
            "healthy": len([i for i in self.dead if self.dead.get(i, 0) <= time.time()]),
            "tested": len(self.dead),
            "index": self.idx,
            "current": cur,
            "rotations": self.rotations,
            "served": self.served,
            "failed": self.failed,
            "uptime": int(time.time() - self.started),
            "ts": int(time.time()),
        }
        tmp = STATE + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(data, f, separators=(",", ":"))
            os.replace(tmp, STATE)
        except Exception:
            pass


# ---------------------------------------------------------------- upstreams
async def connect_http(up, target_host, target_port):
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(up["host"], up["port"]), CONNECT_TIMEOUT)
    req = "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n" % (
        target_host, target_port, target_host, target_port)
    if up["user"]:
        token = base64.b64encode(("%s:%s" % (up["user"], up["pass"])).encode()).decode()
        req += "Proxy-Authorization: Basic %s\r\n" % token
    req += "Proxy-Connection: keep-alive\r\n\r\n"
    writer.write(req.encode())
    await asyncio.wait_for(writer.drain(), CONNECT_TIMEOUT)
    head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), CONNECT_TIMEOUT)
    if len(head) > HEADER_LIMIT:
        raise ValueError("upstream header too large")
    status = head.split(b"\r\n", 1)[0]
    if b" 200" not in status:
        raise ValueError("upstream refused CONNECT: %s" % status.decode("latin-1", "replace"))
    return reader, writer


async def connect_socks5(up, target_host, target_port):
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(up["host"], up["port"]), CONNECT_TIMEOUT)
    if up["user"]:
        writer.write(b"\x05\x01\x02")
        await writer.drain()
        if await asyncio.wait_for(reader.readexactly(2), CONNECT_TIMEOUT) != b"\x05\x02":
            raise ValueError("socks5: auth method refused")
        u, p = up["user"].encode(), up["pass"].encode()
        writer.write(b"\x01" + bytes([len(u)]) + u + bytes([len(p)]) + p)
        await writer.drain()
        if (await asyncio.wait_for(reader.readexactly(2), CONNECT_TIMEOUT))[1] != 0:
            raise ValueError("socks5: credentials refused")
    else:
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        if (await asyncio.wait_for(reader.readexactly(2), CONNECT_TIMEOUT))[1] != 0:
            raise ValueError("socks5: no-auth refused")

    try:
        host_bytes = target_host.encode("idna")
        atyp = b"\x03" + bytes([len(host_bytes)]) + host_bytes
    except Exception:
        import ipaddress
        ip = ipaddress.ip_address(target_host)
        atyp = (b"\x01" if ip.version == 4 else b"\x04") + ip.packed
    writer.write(b"\x05\x01\x00" + atyp + target_port.to_bytes(2, "big"))
    await writer.drain()
    rep = await asyncio.wait_for(reader.readexactly(4), CONNECT_TIMEOUT)
    if rep[1] != 0:
        raise ValueError("socks5: connect failed (%d)" % rep[1])
    if rep[3] == 1:
        await reader.readexactly(4 + 2)
    elif rep[3] == 3:
        n = (await reader.readexactly(1))[0]
        await reader.readexactly(n + 2)
    elif rep[3] == 4:
        await reader.readexactly(16 + 2)
    return reader, writer


async def connect_via(up, target_host, target_port):
    if up["scheme"] == "direct":
        return await asyncio.wait_for(
            asyncio.open_connection(target_host, target_port), CONNECT_TIMEOUT)
    if up["scheme"].startswith("socks"):
        return await connect_socks5(up, target_host, target_port)
    return await connect_http(up, target_host, target_port)


# ------------------------------------------------------------------ serving
async def pipe(src, dst):
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def tunnel(mux, client_r, client_w, target_host, target_port):
    tried = set()
    for _ in range(MAX_TRIES):
        i = mux.pick()
        if i is None:
            break
        if i in tried:
            i = mux.rotate()
            if i is None or i in tried:
                break
        tried.add(i)
        up = mux.pool[i]
        try:
            ur, uw = await connect_via(up, target_host, target_port)
        except Exception as e:
            mux.mark_dead(i)
            mux.rotate()
            continue
        mux.served += 1
        mux.persist()
        client_w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await client_w.drain()
        await asyncio.gather(pipe(client_r, uw), pipe(ur, client_w))
        return
    try:
        client_w.write(b"HTTP/1.1 502 Bad Gateway\r\n"
                       b"Content-Length: 0\r\nConnection: close\r\n\r\n")
        await client_w.drain()
    except Exception:
        pass
    try:
        client_w.close()
    except Exception:
        pass


async def handle(mux, reader, writer):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 15)
    except Exception:
        try:
            writer.close()
        except Exception:
            pass
        return
    if len(head) > HEADER_LIMIT:
        try:
            writer.close()
        except Exception:
            pass
        return
    first = head.split(b"\r\n", 1)[0].decode("latin-1", "replace") if head else ""
    parts = first.split()
    if len(parts) < 2:
        writer.close()
        return
    method = parts[0].upper()
    target = parts[1]
    if method == "CONNECT":
        host, _, port = target.rpartition(":")
        if not host or not port.isdigit():
            writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        await tunnel(mux, reader, writer, host, int(port))
    else:
        # plain HTTP through the upstream: absolute-URI form only
        if not target.startswith("http://"):
            writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        rest = target[7:]
        hostport, _, _path = rest.partition("/")
        host, _, port = hostport.rpartition(":")
        if not port.isdigit():
            host, port = hostport, "80"
        await tunnel(mux, reader, writer, host, int(port))


async def watch_commands(mux):
    """rotate on demand: `echo rotate > guard/proxy-cmd`."""
    while True:
        await asyncio.sleep(1.0)
        try:
            if os.path.exists(CMD):
                with open(CMD) as f:
                    cmd = f.read().strip().lower()
                os.unlink(CMD)
                if cmd.startswith("rotate"):
                    mux.rotate()
                elif cmd.startswith("reload"):
                    mux.pool = load_pool()
                    mux.dead = seed_health(mux.pool)
                    mux.apply_conf()
                    mux.persist()
        except Exception:
            pass


async def main():
    pool = load_pool()
    if not pool:
        # a mux with no pool is a closed door: better to refuse than to
        # silently serve direct traffic and pretend it is rotation.
        print("proxy-mux: no usable upstreams in %s — refusing to start" % POOL, file=sys.stderr)
        return 2
    mux = Mux(pool)
    server = await asyncio.start_server(lambda r, w: handle(mux, r, w), HOST, PORT)
    print("proxy-mux: %d upstreams on %s:%d (policy %s)" % (len(pool), HOST, PORT, POLICY))
    asyncio.ensure_future(watch_commands(mux))
    # a SIGTERM is how the CLI stops us. turn it into an exit so the finally
    # below runs — a machine pointed at a stopped mux is a dead internet.
    try:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    except Exception:
        pass
    async with server:
        try:
            await server.serve_forever()
        finally:
            restore_system()


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(0)
