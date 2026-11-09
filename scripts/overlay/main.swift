// opencode-unlimited overlay — always-on-top mini HUD.
//
// one borderless non-activating panel that runs the real commands
// (zen-hop.sh, doctor.sh) and shows the real token ledger out of
// ~/.local/share/opencode/opencode.db. no fake numbers, no decorative
// buttons: every control maps to a process on this machine.
//
// the whole thing collapses into a circular bubble that keeps floating and
// expands back on click. drag it anywhere; it snaps to the screen edges.

import Cocoa
import WebKit

let brand = "opencode-unlimited"
let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let dest = home.appendingPathComponent(".local/share/\(brand)")
let scripts = dest.appendingPathComponent("scripts")
let guardDir = dest.appendingPathComponent("guard")
let ctxFile = guardDir.appendingPathComponent("overlay-context.json")
let cmdFile = guardDir.appendingPathComponent("overlay-cmd")
// .standard resolves to this bundle's domain (com.opencode-unlimited.overlay),
// which is the same one `defaults read com.opencode-unlimited.overlay` shows.
// naming the suite explicitly is a no-op macOS warns about.
let defaults = UserDefaults.standard

// one append-only line per surprise. no crash reporter, no permission prompt —
// just enough to know why the panel died the next time it does.
let crashFile = guardDir.appendingPathComponent("overlay-crash.log")
func crashLog(_ msg: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(stamp)] \(msg)\n".data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: crashFile) {
        h.seekToEndOfFile()
        h.write(data)
        let end = h.offsetInFile
        try? h.close()
        if end > 256 * 1024 { try? FileManager.default.removeItem(at: crashFile) }
    } else {
        try? data.write(to: crashFile)
    }
}

let EXPANDED = NSSize(width: 366, height: 642)
let COLLAPSED = NSSize(width: 78, height: 78)

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// plain container. it used to return nil from hitTest to "let drags through",
// which also told AppKit the whole content view was untouchable — the web view
// inside it never received a single mouseDown, so every button was dead while
// the UI still rendered. dragging is driven from js (dragStart/dragEnd), not
// from the container swallowing events.
final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    // accessory app, never active: without this AppKit spends the first click
    // of every interaction on activation and the button underneath never fires.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// the hit target is the web view, not the container, so it needs the same
// first-mouse pass-through — otherwise buttons only work on the second click,
// and there is never a first click because nothing activates the app.
final class Web: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var window: Panel!
    var web: WKWebView!
    var dragTimer: Timer?
    var dragStartMouse = NSPoint.zero
    var dragStartOrigin = NSPoint.zero
    var collapsed = false
    var busy = false
    var statusBusy = false
    var pendingRefresh = false
    var poll: Timer?
    var cmdWatch: Timer?
    var lastCmdStamp: TimeInterval = 0
    var lastCmdText: String = ""
    var reassertWork: DispatchWorkItem?
    var blankTicks = 0
    var lastStatus: String = "{}"
    // hidden means the user put the panel away. nothing may order it front
    // while this is true — not a space switch, not an app activation, not the
    // health tick. the lane clears it on the next opencode launch.
    var hidden = false
    var statusItem: NSStatusItem?
    var reloadAttempts = 0
    var warpChecks = 0
    var warpMiss = 0
    var warpFixAt: TimeInterval = 0
    var lastDump: TimeInterval = 0
    // the HUD is a companion to a live session: when the lane raised it and the
    // last session went away, it puts itself back. a panel the user opened by
    // hand is left alone.
    var openedByLane = false
    var idleTicks = 0
    var bootIntent: String = ""
    // the user asked for the panel and has not hidden it since. a pinned panel
    // ignores the session watcher; an auto-raised one follows opencode.
    var pinned = false
    var tickCount = 0
    // the user closed the panel deliberately. the session watcher must not
    // reopen it until they ask again — otherwise ✕ does nothing.
    var manualHide = false

    // ---------------------------------------------------------------- boot
    func applicationDidFinishLaunching(_ n: Notification) {
        // a stray --session-dir from the lane becomes the project label
        var args = CommandLine.arguments
        args.removeFirst()
        var i = 0
        while i < args.count {
            if args[i] == "--session-dir", i + 1 < args.count {
                writeContext(dir: args[i + 1])
                i += 2
                continue
            }
            // launched by the lane: this instance belongs to a session and is
            // allowed to step back when that session ends.
            if args[i] == "--summon" { openedByLane = true; bootIntent = "summon" }
            if args[i] == "--show" { bootIntent = "show" }
            i += 1
        }

        crashLog("launch pid=\(ProcessInfo.processInfo.processIdentifier)")
        evictOlderInstances()
        launchGuard()
        buildWindow()
        buildWebView()
        restoreFrame()
        // a panel the user dismissed stays dismissed across a relaunch.
        // the lane opens it again when opencode starts.
        hidden = defaults.bool(forKey: "hidden")
        if openedByLane { hidden = false }

        // the launcher leaves an intent marker so a real summon is never
        // mistaken for a bare boot. the process then stays resident either way:
        // resident-but-hidden still raises itself the moment opencode appears,
        // which is what makes detection instant instead of a cold start.
        if bootIntent.isEmpty { bootIntent = readIntent() }
        if openedByLane || bootIntent == "summon" {
            openedByLane = true; pinned = false; manualHide = false; hidden = false
        }
        if bootIntent == "show" { pinned = true; manualHide = false; hidden = false }
        buildStatusItem()
        // an NSWindow that is created is not on screen until it is ordered in,
        // and `open -g` never activates us. orderFrontRegardless is the only
        // call that puts a non-activating panel in front without stealing focus.
        if !hidden { window.orderFrontRegardless() }

        // every space switch and every app activation is a chance for the window
        // server to leave a panel behind. re-order it front, without activating.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reassertSoon()
            }
        }

        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            // nobody is looking at a hidden panel. the session watcher still runs
            // every tick; the status probe drops to every fourth (8s), which is
            // 1/4 the process spawns and still instant to the eye on show.
            self.tickCount += 1
            if !self.hidden || self.tickCount % 4 == 0 { self.refresh(force: false) }
            self.healthTick()
            self.warpWindowTick()
            self.sessionTick()
            // the state file is read by tooling, not by a person — 5s is plenty
            // and it keeps a 2s timer from doing two disk writes every tick.
            let now = Date().timeIntervalSince1970
            if now - self.lastDump >= 5 {
                self.lastDump = now
                self.dumpState()
            }
        }
        seedCommandCursor()
        cmdWatch = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            self.watchCommandFile()
        }
        refresh(force: true)
        dumpState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.settleBoot() }
        if ProcessInfo.processInfo.arguments.contains("--collapsed") {
            setCollapsed(true, animate: false)
        }
    }

    // false, always. the panel is hidden and shown all day, and AppKit treats
    // ordering out the only window as closing the last one — which used to end
    // the process the moment it hid itself. quitting is the menu item only.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // the launcher writes "summon <unix ts>" or "show <unix ts>" and then starts
    // the app. launchctl kickstart cannot pass arguments, so this marker is how
    // a cold start knows it was asked for. stale markers are ignored.
    func readIntent() -> String {
        let f = guardDir.appendingPathComponent("overlay-intent")
        guard let raw = try? String(contentsOf: f, encoding: .utf8) else { return "" }
        // trim first: Double("123\n") is nil, and the marker ends with a newline
        let parts = raw.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard parts.count == 2, let ts = Double(parts[1]),
              Date().timeIntervalSince1970 - ts < 15 else { return "" }
        return String(parts[0])
    }

    func shouldStay() -> Bool {
        if pinned || openedByLane || bootIntent == "summon" || bootIntent == "show" { return true }
        return sessionCount() > 0
    }

    // this process stays resident. it used to exit when no session existed, and
    // the cost of that was a 1-3s cold start every time opencode appeared — the
    // panel arrived after the first message had already been typed. resident,
    // the watcher below sees opencode within one 2s tick and the window is
    // already built, so the raise is instant. an idle instance owns no window
    // and costs a few MB.
    //
    // the first few seconds are a grace period: a session launched by the lane
    // is writing its marker while we boot.
    func settleBoot() {
        guard !shouldStay() else { return }
        crashLog("no opencode running — resident, panel hidden")
        if !hidden { setHidden(true, remember: false) }
    }

    // launchd restarts this app every few seconds when it dies. if it dies from
    // something that reproduces on boot, that becomes a spin that pegs a core
    // and churns the crash log. count launches in a rolling window and, past a
    // threshold, wait before building anything — the loop gets slower instead
    // of hotter, and a human still has a running process to look at.
    func launchGuard() {
        let f = guardDir.appendingPathComponent("overlay-launches.json")
        var stamps: [Double] = []
        if let d = try? Data(contentsOf: f),
           let a = try? JSONSerialization.jsonObject(with: d) as? [Double] { stamps = a }
        let now = Date().timeIntervalSince1970
        stamps = stamps.filter { now - $0 < 120 }
        stamps.append(now)
        if let d = try? JSONSerialization.data(withJSONObject: stamps) { try? d.write(to: f) }
        // 6 launches inside 2 minutes means it is not recovering on its own.
        if stamps.count > 6 {
            crashLog("launch loop detected (\(stamps.count) in 120s) — backing off 30s")
            Thread.sleep(forTimeInterval: 30)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        crashLog("terminate (window visible=\(window?.isVisible ?? false))")
    }

    // the app's own view of whether the panel is actually on screen. CGWindowList
    // cannot answer that without Screen Recording permission, and this can.
    func dumpState() {
        guard window != nil, web != nil else { return }
        var d: [String: Any] = [
            "visible": window.isVisible,
            "occluded": !window.occlusionState.contains(.visible),
            "onActiveSpace": window.isOnActiveSpace,
            "frame": NSStringFromRect(window.frame),
            "level": window.level.rawValue,
            "alpha": Double(window.alphaValue),
            "collapsed": collapsed,
            "dismissed": hidden,
            "policy": NSApp.activationPolicy().rawValue,
            "statusItem": statusItem?.button != nil,
            "appHidden": NSApp.isHidden,
            "webLoaded": !web.isLoading && web.url != nil,
            "ts": Int(Date().timeIntervalSince1970)
        ]
        if let scr = currentScreen() { d["screen"] = NSStringFromRect(scr.visibleFrame) }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) {
            try? data.write(to: guardDir.appendingPathComponent("overlay-state.json"))
        }
    }

    // dump where the web view thinks its controls are. used to prove the panel
    // is hit-testing again: a real click at these coordinates must change state.
    // asks the page what it is currently rendering. used to verify that the
    // 2s status tick is reaching the DOM, not just the native side.
    func probeDom() {
        let js = """
        JSON.stringify({
          tok: (document.getElementById('tokTotal')||{}).textContent,
          unit: (document.getElementById('tokUnit')||{}).textContent,
          tin: (document.getElementById('tokIn')||{}).textContent,
          tout: (document.getElementById('tokOut')||{}).textContent,
          cost: (document.getElementById('tokCost')||{}).textContent,
          sess: (document.getElementById('sessCount')||{}).textContent,
          keyCount: (document.getElementById('keyCount')||{}).textContent,
          keyActive: (document.getElementById('keyActive')||{}).textContent,
          disabled: ['btnKeyAdd','btnKeyPrev','btnKeyNext','btnKeyList','btnKeyDel']
            .filter(function(i){var e=document.getElementById(i);return e&&e.disabled;}),
          updated: (window.oucLastUpdate||0),
          heights: (function(){
            var o = {};
            ['app','hero','grid','keys','health','spark','actions','log','logPanel','logBody'].forEach(function(k){
              var e = document.getElementById(k);
              if (e) o[k] = Math.round(e.getBoundingClientRect().height);
            });
            o.docScroll = document.body.scrollHeight;
            o.viewport = window.innerHeight;
            return o;
          })()
        })
        """
        web.evaluateJavaScript(js) { res, err in
            var body: [String: Any] = ["frame": NSStringFromRect(self.window.frame)]
            if let str = res as? String { body["dom"] = str }
            if let e = err { body["error"] = String(describing: e) }
            if let d = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
                try? d.write(to: guardDir.appendingPathComponent("overlay-dom.json"))
            }
        }
    }

    func measureControls() {
        let js = "JSON.stringify(Array.from(document.querySelectorAll('button,#bubble,#drag,.chip[data-act],#pxChip')).map(e=>{const r=e.getBoundingClientRect();return {id:e.id,x:r.x,y:r.y,w:r.width,h:r.height}}))"
        web.evaluateJavaScript(js) { res, err in
            var body: [String: Any] = ["frame": NSStringFromRect(self.window.frame)]
            if let s = res as? String { body["controls"] = s }
            if let e = err { body["error"] = String(describing: e) }
            if let d = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
                try? d.write(to: guardDir.appendingPathComponent("overlay-rect.json"))
            }
        }
    }

    func writeContext(dir: String) {
        try? fm.createDirectory(at: guardDir, withIntermediateDirectories: true)
        let body: [String: Any] = ["dir": dir, "ts": Int(Date().timeIntervalSince1970)]
        if let d = try? JSONSerialization.data(withJSONObject: body) {
            try? d.write(to: ctxFile)
        }
    }

    // ---------------------------------------------------------------- window
    func buildWindow() {
        window = Panel(contentRect: NSRect(origin: .zero, size: EXPANDED),
                       styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        let host = DragView(frame: NSRect(origin: .zero, size: EXPANDED))
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor(calibratedRed: 0.13, green: 0.83, blue: 0.93, alpha: 0.26).cgColor
        window.contentView = host

        window.setFrameOrigin(defaultOrigin())
    }

    func defaultOrigin() -> NSPoint {
        let vf = (NSScreen.screens.first?.visibleFrame) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.minX + 18, y: vf.midY - EXPANDED.height / 2)
    }

    func restoreFrame() {
        // always come back as a full panel. a HUD that relaunches into the 78px
        // bubble reads as "it disappeared", and the bubble is one click away
        // anyway. --collapsed still forces it for anyone who wants that.
        collapsed = false
        defaults.set(false, forKey: "collapsed")
        if let str = defaults.string(forKey: "frame") {
            var r = NSRectFromString(str)
            if r.width > 40, r.height > 40, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                // a frame saved by an older layout is too short for the current
                // cards: the console pane gets squeezed to nothing. grow it.
                if !collapsed, r.height < EXPANDED.height { r.size.height = EXPANDED.height }
                if !collapsed, r.width < EXPANDED.width { r.size.width = EXPANDED.width }
                if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(r) }) {
                    let vf = screen.visibleFrame
                    if r.maxY > vf.maxY { r.origin.y = vf.maxY - r.height }
                    if r.minY < vf.minY { r.origin.y = vf.minY }
                    if r.maxX > vf.maxX { r.origin.x = vf.maxX - r.width }
                    if r.minX < vf.minX { r.origin.x = vf.minX }
                }
                window.setFrame(r, display: false)
                applyShape(animate: false)
                return
            }
        }
        applyShape(animate: false)
    }

    func buildWebView() {
        let cfg = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(self, name: "ouc")
        cfg.userContentController = ucc
        cfg.suppressesIncrementalRendering = false

        web = Web(frame: window.contentView!.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        window.contentView!.addSubview(web)

        if let html = Bundle.main.url(forResource: "overlay", withExtension: "html") {
            web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("overlay.html")
            web.loadFileURL(local, allowingReadAccessTo: local.deletingLastPathComponent())
        }
    }

    // NSScreen.main is the screen with the *key* window, and an accessory app
    // that never activates has none. pick by overlap instead.
    func currentScreen() -> NSScreen? {
        let f = window.frame
        let screens = NSScreen.screens
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.visibleFrame.intersection(f)
            return r.isNull ? 0 : r.width * r.height
        }
        if let hit = screens.max(by: { overlap($0) < overlap($1) }), overlap(hit) > 0 {
            return hit
        }
        return screens.first
    }

    func applyShape(animate: Bool) {
        guard let screen = currentScreen() else { return }
        let vf = screen.visibleFrame
        let size = collapsed ? COLLAPSED : EXPANDED
        var f = window.frame
        let top = f.maxY
        let pinnedRight = vf.maxX - f.maxX < 40
        f.size = size
        f.origin.y = top - size.height
        // collapsing against the right edge keeps the right edge, not the
        // left one — otherwise the bubble drifts inward every toggle.
        if pinnedRight { f.origin.x = vf.maxX - size.width - 8 }
        f.origin.x = min(max(f.origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        f.origin.y = min(max(f.origin.y, vf.minY + 4), vf.maxY - size.height - 4)

        let radius: CGFloat = collapsed ? size.width / 2 : 18
        if animate {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.24
                c.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(f, display: true)
            }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.24)
            window.contentView?.layer?.cornerRadius = radius
            CATransaction.commit()
        } else {
            window.setFrame(f, display: true)
            window.contentView?.layer?.cornerRadius = radius
        }
        defaults.set(collapsed, forKey: "collapsed")
        defaults.set(NSStringFromRect(f), forKey: "frame")
        push("window", ["collapsed": collapsed])
    }

    // coalesce a burst of space/activation notifications into one order call
    func reassertSoon() {
        reassertWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.window != nil else { return }
            guard !self.hidden else { self.dumpState(); return }
            if !self.window.isVisible { self.window.orderFrontRegardless() }
            self.window.orderFrontRegardless()
            self.dumpState()
        }
        reassertWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    // a stale command file must never fire on boot. the cursor starts at the
    // file's current contents, so only a *new* write is acted on.
    func seedCommandCursor() {
        guard let attrs = try? fm.attributesOfItem(atPath: cmdFile.path),
              let stamp = attrs[.modificationDate] as? Date else { return }
        lastCmdStamp = stamp.timeIntervalSince1970
        lastCmdText = (try? String(contentsOf: cmdFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // cheap liveness: a web process that died leaves an empty page, and a
    // window that was ordered out never comes back on its own.
    // the WARP GUI is a menu bar app. after a sleep, a crash restart or a
    // display change it can end up running with no usable window: `open -a`
    // then does nothing, which is exactly what "cloudflare will not open"
    // looks like. the daemon keeps the tunnel up the whole time, so nothing
    // else reports a fault. check the window every 30s and relaunch only the
    // GUI (never the root daemon) when it is gone. at most once every 10 min.
    func warpWindowTick() {
        warpChecks += 1
        guard warpChecks % 2 == 0 else { return }    // 2s poll × 2 = 4s
        let now = Date().timeIntervalSince1970
        let app = NSWorkspace.shared.runningApplications.first(
            where: { ($0.bundleIdentifier ?? "").contains("cloudflare.1dot1dot1") })
        // no GUI at all: the tunnel lives in the root daemon, so this is only
        // the window being gone. open it, and never more than once every 10min.
        guard let app = app else {
            guard now - warpFixAt > 600 else { return }
            warpFixAt = now
            crashLog("warp GUI not running — opening it")
            openWarp()
            return
        }
        let pid = app.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        let usable = list.contains { w in
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let b = w[kCGWindowBounds as String] as? [String: Any] else { return false }
            let ww = b["Width"] as? Double ?? 0
            let hh = b["Height"] as? Double ?? 0
            return ww >= 300 && hh >= 300
        }
        // two misses in a row before touching anything: a window that is
        // rebuilding itself must not get killed mid-animation.
        if usable { warpMiss = 0; return }
        warpMiss += 1
        guard warpMiss >= 2 else { return }
        guard now - warpFixAt > 600 else { return }
        warpMiss = 0
        warpFixAt = now
        crashLog("warp GUI has no window — relaunching it (tunnel untouched)")
        push("log", ["line": "warp UI had no window — restarted the app"])
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "Cloudflare WARP.app/Contents/MacOS/"]
        try? kill.run()
        kill.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.openWarp()
        }
    }

    // two independent answers to "is opencode running", because either one
    // alone lies:
    //
    //  · the lane drops guard/sessions/<pid> for anything it launched — precise,
    //    but silent for an opencode started outside the wrapper
    //  · the process table — catches every launch, including a bare `opencode`
    //    from a shell whose PATH predates the installer
    //
    // `opencode serve` is always up and is not a session, so a `serve` argv is
    // excluded. the panel's own process is excluded by name.
    func markerCount() -> Int {
        let dir = guardDir.appendingPathComponent("sessions")
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var live = 0
        for n in names where !n.hasPrefix(".") {
            guard let pid = pid_t(n) else { continue }
            if kill(pid, 0) == 0 { live += 1 }
            else { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        }
        return live
    }

    func processCount() -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,comm=,args="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return 0 }
        let me = ProcessInfo.processInfo.processIdentifier
        var n = 0
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = pid_t(f[0]), pid != me else { continue }
            let args = String(f[2])
            // argv[0], because `comm` is truncated to 16 bytes and the real
            // binary is `.../@opencode/cli/bin/opencode.exe` — matching comm
            // never found it. the first word always names the executable.
            let argv0 = args.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let name = (argv0 as NSString).lastPathComponent
            guard name == "opencode" || name == "opencode.exe" else { continue }
            // `opencode serve --service` is the always-on daemon, not a session
            if args.contains(" serve") || args.hasSuffix("serve") { continue }
            if name == "opencode-unlimited-overlay" { continue }
            n += 1
        }
        return n
    }

    func sessionCount() -> Int { max(markerCount(), processCount()) }

    // the watcher. nothing is launched here — the process is already running,
    // so raising the panel is a window order, not a cold start.
    func sessionTick() {
        let n = sessionCount()
        if n > 0 {
            idleTicks = 0
            if hidden && !pinned && !manualHide {
                crashLog("opencode detected — raising the HUD")
                openedByLane = true
                setHidden(false, remember: false)
            }
            return
        }
        guard !pinned, !manualHide else { idleTicks = 0; return }
        guard !hidden else { idleTicks = 0; return }
        idleTicks += 1
        // 2s poll × 30 = a minute of no session before the panel steps back
        if idleTicks >= 30 {
            idleTicks = 0
            openedByLane = false
            crashLog("no opencode session for 60s — hiding the HUD")
            setHidden(true, remember: false)
        }
    }

    func healthTick() {
        if !hidden, !window.isVisible { window.orderFrontRegardless() }
        if web.url == nil && !web.isLoading {
            blankTicks += 1
            if blankTicks >= 3 { blankTicks = 0; reloadPage() }
        } else {
            blankTicks = 0
        }
    }

    func reloadPage() {
        web.stopLoading()
        web.loadFileURL(pageURL(), allowingReadAccessTo: pageURL().deletingLastPathComponent())
    }

    func pageURL() -> URL {
        if let html = Bundle.main.url(forResource: "overlay", withExtension: "html") { return html }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("overlay.html")
    }

    func setCollapsed(_ v: Bool, animate: Bool) {
        // asking for a panel is asking to see it.
        if !v && hidden { setHidden(false) }
        if collapsed == v {
            if !hidden { window.orderFrontRegardless() }
            return
        }
        collapsed = v
        applyShape(animate: animate)
        if !hidden { window.orderFrontRegardless() }
    }

    // the only real close the panel has. the process stays resident so the
    // lane can raise it again without a relaunch, but nothing re-orders it
    // while hidden is set.
    func setHidden(_ v: Bool, remember: Bool = true, manual: Bool = false) {
        if v && manual { manualHide = true }
        if !v { manualHide = false }
        hidden = v
        if remember { defaults.set(v, forKey: "hidden") }
        if v {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
        updateStatusItem()
        dumpState()
        push("window", ["collapsed": collapsed, "hidden": hidden])
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = NSImage(systemSymbolName: "bolt.horizontal.circle",
                                accessibilityDescription: "opencode unlimited")
            btn.image?.isTemplate = true
            btn.toolTip = "opencode unlimited"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show HUD", action: #selector(menuShow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide HUD", action: #selector(menuHide), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Collapse to bubble", action: #selector(menuBubble), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload HUD", action: #selector(menuReload), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Cloudflare WARP", action: #selector(menuWarp), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Restart Cloudflare WARP UI", action: #selector(menuRestartWarp), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit HUD", action: #selector(menuQuit), keyEquivalent: "q"))
        for mi in menu.items { mi.target = self }
        item.menu = menu
        statusItem = item
        updateStatusItem()
    }

    func updateStatusItem() {
        guard let btn = statusItem?.button else { return }
        btn.appearsDisabled = hidden
    }

    @objc func menuShow() { openedByLane = false; pinned = true; manualHide = false; setHidden(false); setCollapsed(false, animate: true) }
    @objc func menuHide() { setHidden(true) }
    @objc func menuBubble() { setHidden(false); setCollapsed(true, animate: true) }
    @objc func menuReload() { setHidden(false); reloadPage() }
    // KeepAlive would put it straight back. bootout the agent first, so "Quit"
    // means quit until the next login (or `opencode-unlimited-overlay show`,
    // which launches the app directly and does not need the agent).
    @objc func menuQuit() { quitForReal() }

    func quitForReal() {
        crashLog("quit requested")
        defaults.set(false, forKey: "hidden")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/com.opencode-unlimited.overlay"]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }
    @objc func menuWarp() { openWarp() }

    // the WARP GUI is a menu bar app. it can come back from a sleep or a crash
    // with a zero-size window: the daemon keeps the tunnel up, so nothing looks
    // broken, but clicking the app does nothing. activating is enough when the
    // window exists; when it does not, the GUI has to be relaunched (the root
    // daemon is untouched, so the tunnel never drops).
    func openWarp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Cloudflare WARP"]
        try? p.run()
    }

    @objc func menuRestartWarp() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "Cloudflare WARP.app/Contents/MacOS/"]
        try? kill.run()
        kill.waitUntilExit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.openWarp()
        }
    }

    func saveFrame() {
        defaults.set(NSStringFromRect(window.frame), forKey: "frame")
    }

    // ---------------------------------------------------------------- drag
    func beginDrag() {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window.frame.origin
        dragTimer?.invalidate()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 90.0, repeats: true) { _ in
            let m = NSEvent.mouseLocation
            var f = self.window.frame
            f.origin = NSPoint(x: self.dragStartOrigin.x + (m.x - self.dragStartMouse.x),
                               y: self.dragStartOrigin.y + (m.y - self.dragStartMouse.y))
            self.window.setFrame(f, display: true)
        }
    }

    func endDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        snap()
        saveFrame()
    }

    func snap() {
        guard let screen = currentScreen() else { return }
        let vf = screen.visibleFrame
        let m: CGFloat = 30
        var f = window.frame
        if f.minX - vf.minX < m { f.origin.x = vf.minX + 8 }
        if vf.maxX - f.maxX < m { f.origin.x = vf.maxX - f.width - 8 }
        if f.minY - vf.minY < m { f.origin.y = vf.minY + 8 }
        if vf.maxY - f.maxY < m { f.origin.y = vf.maxY - f.height - 8 }
        if f.origin != window.frame.origin {
            window.setFrame(f, display: true)
        }
    }

    func dockSide() {
        guard let screen = currentScreen() else { return }
        let vf = screen.visibleFrame
        var f = window.frame
        let left = f.midX < vf.midX
        f.origin.x = left ? vf.maxX - f.width - 8 : vf.minX + 8
        // set, don't animate: animator().setFrame returns immediately and the
        // frame we would persist is the pre-animation one.
        window.setFrame(f, display: true)
        saveFrame()
    }

    // ---------------------------------------------------------------- js
    func push(_ type: String, _ payload: [String: Any]) {
        guard let web = web else { return }
        let obj: [String: Any] = ["type": type, "payload": payload]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) {
            web.evaluateJavaScript("window.ouc && window.ouc(\(s));", completionHandler: nil)
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "dragStart": beginDrag()
        case "dragEnd": endDrag()
        case "collapse": setCollapsed(true, animate: true)
        case "expand":
            setHidden(false)
            setCollapsed(false, animate: true)
            window.orderFrontRegardless()
        case "dock": dockSide()
        case "state": dumpState()
        case "reload": reloadPage()
        case "keyrotate": keyCmd(["rotate"])
        case "keylist": keyCmd(["health"])
        case "rect": measureControls()
        case "dom": probeDom()
        // the panel's X puts it away for real. the process is still there, the
        // menu bar item brings it back, and the lane raises it on the next
        // opencode launch — so a stray click cannot lose it, but it also
        // cannot sit on top of everything forever.
        case "hide": setHidden(true, manual: true)
        case "show": openedByLane = false; pinned = true; manualHide = false; setHidden(false)
        case "summon": openedByLane = true; pinned = false; manualHide = false; idleTicks = 0; setHidden(false); setCollapsed(false, animate: true)
        case "warp": openWarp()
        case "close": setCollapsed(true, animate: true)
        case "refresh": refresh(force: true)
        case "copy": copySummary()
        case "hop": runCommand("hop")
        case "where": runCommand("where")
        case "doctor": runCommand("doctor")
        case "keyList": keyCmd(["health"])
        case "keyPrune": keyCmd(["prune"])
        case "keyCurrent": keyCmd(["current"])
        case "keyRotate":
            // forward and backward are first-class: a wall can be cleared by
            // moving to the next key or by stepping back onto a healthy one.
            let dir = (body["dir"] as? String) ?? "next"
            keyCmd(["rotate", dir == "prev" ? "prev" : "next"])
        case "keyRemove":
            if let slot = body["slot"] as? String, !slot.isEmpty { keyCmd(["remove", slot]) }
        case "keyAdd":
            if let k = body["key"] as? String, !k.isEmpty { keyCmd(["add", k]) }
        // ---- proxy sheet. every one of these runs proxy-pool.sh for real.
        case "proxyList": proxyCmd(["json"], json: true)
        case "proxyAdd":
            if let spec = body["spec"] as? String, !spec.isEmpty { proxyCmd(["add", spec]) }
        case "proxyRemove":
            if let slot = body["slot"] as? String, !slot.isEmpty { proxyCmd(["remove", slot]) }
        case "proxyRotate":
            if let slot = body["slot"] as? String, !slot.isEmpty { proxyCmd(["rotate", slot]) }
            else { proxyCmd(["rotate"]) }
        case "proxyOn": proxyCmd(["on"])
        case "proxyOff": proxyCmd(["off"])
        case "proxyTest": proxyCmd(["test"])
        case "proxySys":
            proxyCmd(["sys", (body["on"] as? String) == "on" ? "on" : "off"])
        case "proxyPolicy":
            proxyCmd(["policy", (body["value"] as? String) == "window" ? "window" : "conn"])
        // ---- model levers. the free tier is one bucket per model, and the
        // wall message itself says "or switch models".
        case "modelList": modelCmd(["json"], json: true)
        case "modelSet":
            if let id = body["id"] as? String, !id.isEmpty { modelCmd(["set", id]) }
        case "modelNext": modelCmd(["next"])
        case "modelBurn": modelCmd(["burn-current"])
        case "modelReset": modelCmd(["reset"])
        case "modelRefresh": modelCmd(["refresh"])
        default: break
        }
    }

    // ---------------------------------------------------------------- data
    func refresh(force: Bool) {
        if statusBusy { pendingRefresh = pendingRefresh || force; return }
        statusBusy = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scripts.appendingPathComponent("status.sh").path] + (force ? ["--force"] : [])
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["OUC_STATUS_TTL"] = "12"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                DispatchQueue.main.async { self.statusBusy = false }
                return
            }
            // a status probe that hangs (dead network, wedged sqlite) would
            // hold statusBusy forever and freeze the HUD. kill it after 12s.
            let watchdog = DispatchWorkItem {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            let out = String(data: data, encoding: .utf8) ?? "{}"
            DispatchQueue.main.async {
                self.statusBusy = false
                if out.hasPrefix("{") {
                    self.lastStatus = out
                    self.web.evaluateJavaScript("window.oucUpdate && window.oucUpdate(\(out));", completionHandler: nil)
                }
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh(force: true) }
                }
            }
        }
    }

    // the key pool is deliberately driven by the same shell script a terminal
    // uses, so what the HUD shows and what `api-keys.sh` does can never drift.
    func keyCmd(_ args: [String]) {
        push("keysBusy", ["on": true])
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scripts.appendingPathComponent("api-keys.sh").path] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["TERM"] = "dumb"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    self.push("keysBusy", ["on": false])
                    self.push("toast", ["text": "api-keys.sh not installed"])
                }
                return
            }
            // a liveness probe can take 12s. cap it so a black-hole network
            // does not leave the ADD/ROTATE buttons greyed out forever.
            let watchdog = DispatchWorkItem {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            let out = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.push("keysBusy", ["on": false])
                self.push("keysOut", ["text": out, "ok": p.terminationStatus == 0])
                self.refresh(force: true)
            }
        }
    }

    // proxy-pool.sh and model-levers.sh both answer in two flavours: plain
    // text for the console, and json for the sheet's lists. one runner, a tag
    // per tool, so a third lever costs three lines instead of forty.
    func toolCmd(_ script: String, _ args: [String], json: Bool = false, tag: String) {
        push("\(tag)Busy", ["on": true])
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [scripts.appendingPathComponent(script).path] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["TERM"] = "dumb"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch {
                DispatchQueue.main.async {
                    self.push("\(tag)Busy", ["on": false])
                    self.push("toast", ["text": "\(script) not installed"])
                }
                return
            }
            // TEST probes every upstream through a real CONNECT; a full pool is
            // minutes of work at 14s a probe, so the cap is generous. anything
            // past it is a wedged process, not a slow proxy.
            let watchdog = DispatchWorkItem {
                guard p.isRunning else { return }
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            let out = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.push("\(tag)Busy", ["on": false])
                if json {
                    self.push("\(tag)State", ["json": out])
                } else {
                    self.push("\(tag)Out", ["text": out, "ok": p.terminationStatus == 0])
                }
                self.refresh(force: true)
            }
        }
    }

    func proxyCmd(_ args: [String], json: Bool = false) {
        toolCmd("proxy-pool.sh", args, json: json, tag: "proxy")
    }

    func modelCmd(_ args: [String], json: Bool = false) {
        toolCmd("model-levers.sh", args, json: json, tag: "model")
    }

    func copySummary() {
        var text = "opencode unlimited — status\n"
        if let d = try? JSONSerialization.jsonObject(with: Data(lastStatus.utf8)) as? [String: Any] {
            if let id = d["identity"] as? [String: Any] {
                text += "egress /64: \(id["prefix"] ?? "?")\n"
                text += "ipv6 exit: \(id["seen6"] ?? "?")\n"
                text += "device: \(id["device"] ?? "?")\n"
                text += "hops: \(id["hops"] ?? 0)\n"
            }
            if let w = d["warp"] as? [String: Any] {
                text += "warp: \(w["connected"] as? Bool == true ? "connected" : "down") · \(w["mode"] ?? "")\n"
            }
            if let t = d["tokens"] as? [String: Any] {
                text += "tokens: in \(t["input"] ?? 0) · out \(t["output"] ?? 0) · cache \(t["cacheRead"] ?? 0)\n"
                text += "cost: $\(t["cost"] ?? 0)\n"
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        push("toast", ["text": "copied"])
    }

    // ---------------------------------------------------------------- commands
    func runCommand(_ which: String) {
        if busy {
            push("toast", ["text": "busy — \(which) is running"])
            return
        }
        busy = true
        push("busy", ["cmd": which, "on": true])

        // "where" is the read-only question: what identity am i on right now.
        // it runs the same script as the hop with a flag that never touches
        // the tunnel, so asking cannot cost a registration.
        let isHopScript = (which == "hop" || which == "where")
        let path = scripts.appendingPathComponent(isHopScript ? "zen-hop.sh" : "doctor.sh").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = (which == "where") ? [path, "--where"] : [path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "dumb"
        env["OUC_OVERLAY"] = "1"
        // the doctor is usually run *from* the HUD. tell it who we are, so its
        // liveness check cannot report the panel we are drawing on as missing.
        env["OUC_OVERLAY_PID"] = String(getpid())
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()

        // a hop or a doctor that never exits (dead tunnel, a sudo prompt with
        // nowhere to type) would hold `busy` forever and refuse every command
        // after it. 90s is longer than any real run, short enough to recover.
        let watchdog = DispatchWorkItem { [weak self] in
            guard p.isRunning else { return }
            DispatchQueue.main.async {
                self?.push("log", ["line": "… \(which) exceeded 90s — stopping it"])
            }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)

        var buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if d.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            guard var s = String(data: d, encoding: .utf8) else { return }
            s = s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            buffer += s
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<nl])
                buffer = String(buffer[buffer.index(after: nl)...])
                DispatchQueue.main.async { self.push("log", ["line": line]) }
            }
        }
        p.terminationHandler = { proc in
            watchdog.cancel()
            DispatchQueue.main.async {
                if !buffer.isEmpty { self.push("log", ["line": buffer]) }
                self.busy = false
                self.push("busy", ["cmd": which, "on": false, "code": proc.terminationStatus])
                self.refresh(force: true)
            }
        }
    }

    // external control: echo toggle > guard/overlay-cmd
    func watchCommandFile() {
        guard let attrs = try? fm.attributesOfItem(atPath: cmdFile.path),
              let stamp = attrs[.modificationDate] as? Date else { return }
        let t = stamp.timeIntervalSince1970
        guard let raw = try? String(contentsOf: cmdFile, encoding: .utf8) else { return }
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // two writes inside the same second share an mtime — compare the
        // content too, or the second command is silently dropped.
        guard t > lastCmdStamp || cmd != lastCmdText else { return }
        lastCmdStamp = t
        lastCmdText = cmd
        switch cmd {
        case "toggle": setCollapsed(!collapsed, animate: true)
        case "expand": setHidden(false); setCollapsed(false, animate: true)
        case "collapse": setCollapsed(true, animate: true)
        case "hop": runCommand("hop")
        case "doctor": runCommand("doctor")
        case "dock": dockSide()
        case "state": dumpState()
        case "rect": measureControls()
        case "dom": probeDom()
        case "reload": reloadPage()
        case "keyrotate": keyCmd(["rotate"])
        case "keylist": keyCmd(["health"])
        case "keyprune": keyCmd(["prune"])
        case "snapshot": snapshot(to: cmdFile.deletingLastPathComponent().appendingPathComponent("overlay-snapshot.png"))
        case "probe":
            // the probe also reports what the sheet's model rows actually say
            // and where they sit: a row click that selects the wrong model is
            // only visible if the rendered order and the payload order can be
            // compared side by side.
            let js = """
            JSON.stringify({
              title: document.title,
              nodes: document.querySelectorAll('*').length,
              txt: document.body.innerText.slice(0,200),
              modelRows: Array.from(document.querySelectorAll('.sbody[data-body="models"] .pxr')).slice(0,6).map(r => {
                const b = r.getBoundingClientRect();
                return {t: (r.querySelector('.pxa')||{}).textContent, x: Math.round(b.x), y: Math.round(b.y), h: Math.round(b.height)}
              }),
              sheetOpen: !!document.querySelector('#sheet.on'),
              tab: (document.querySelector('.stab.on')||{}).dataset ? document.querySelector('.stab.on').dataset.sheet : null
            })
            """
            web.evaluateJavaScript(js) { v, e in
                let s = (v as? String) ?? "err: \(String(describing: e))"
                try? s.write(to: cmdFile.deletingLastPathComponent().appendingPathComponent("overlay-probe.txt"), atomically: true, encoding: .utf8)
            }
        // never a real quit: folding to the bubble is the only close the HUD
        // offers, so a stray click (or a stale command) cannot take it down.
        case "close": setCollapsed(true, animate: true)
        case "hide": setHidden(true, manual: true)
        case "show": openedByLane = false; pinned = true; manualHide = false; setHidden(false)
        case "summon": openedByLane = true; pinned = false; manualHide = false; idleTicks = 0; setHidden(false); setCollapsed(false, animate: true)
        case "warp": openWarp()
        case "quit": quitForReal()
        default: break
        }
    }

    // proof-of-work for the terminal: write what the window actually shows.
    // WKWebView renders out of process, so an NSView cacheDisplay comes back
    // black — takeSnapshot asks the web process for its own pixels.
    func snapshot(to url: URL) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = window.contentView?.bounds ?? .zero
        web.takeSnapshot(with: cfg) { image, err in
            guard let image = image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                self.push("toast", ["text": "snapshot failed"])
                return
            }
            try? data.write(to: url)
            self.push("toast", ["text": "snapshot saved"])
        }
    }

    // ---------------------------------------------------------------- nav
    func webView(_ webView: WKWebView, didFinish n: WKNavigation!) {
        // the window state and the first status frame can both be produced
        // before the page exists — replay them now that it does.
        web.evaluateJavaScript("window.oucUpdate && window.oucUpdate(\(lastStatus));", completionHandler: nil)
        push("window", ["collapsed": collapsed])
        reloadAttempts = 0
        refresh(force: true)
    }

    // a missing or half-written page used to retry once a second, forever, and
    // flooded the crash log. back off instead: 1s, 2s, 4s … capped at 30s, and
    // reset as soon as the page actually loads.
    func webView(_ webView: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        crashLog("web load failed: \(e.localizedDescription)")
        reloadAttempts += 1
        let delay = min(30.0, pow(2.0, Double(min(reloadAttempts - 1, 5))))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.web.url == nil || !self.web.isLoading else { return }
            self.reloadPage()
        }
    }

    // the web content process is a separate process and it can be killed by the
    // system under memory pressure. without this the window goes white and
    // stays white until something else reloads it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashLog("web content process terminated — reloading")
        reloadAttempts = 0
        reloadPage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }
}

NSSetUncaughtExceptionHandler { ex in
    crashLog("EXCEPTION \(ex.name.rawValue): \(ex.reason ?? "")\n\(ex.callStackSymbols.joined(separator: "\n"))")
}

// exactly one HUD per login session, and it is always the freshest build:
// a rebuild + relaunch must never leave an older binary holding the window.
func evictOlderInstances() {
    guard let id = Bundle.main.bundleIdentifier else { return }
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .filter { $0.processIdentifier != getpid() }
    guard !others.isEmpty else { return }
    crashLog("evicting \(others.count) older instance(s): \(others.map { $0.processIdentifier })")
    for o in others { o.terminate() }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline && others.contains(where: { !$0.isTerminated }) {
        usleep(100_000)
    }
    for o in others where !o.isTerminated {
        kill(o.processIdentifier, SIGKILL)
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
