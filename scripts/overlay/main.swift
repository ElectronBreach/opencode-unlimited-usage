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
let defaults = UserDefaults(suiteName: "com.opencode-unlimited.overlay") ?? .standard

let EXPANDED = NSSize(width: 366, height: 596)
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
    var lastStatus: String = "{}"

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
            i += 1
        }

        buildWindow()
        buildWebView()
        restoreFrame()
        // an NSWindow that is created is not on screen until it is ordered in,
        // and `open -g` never activates us. orderFrontRegardless is the only
        // call that puts a non-activating panel in front without stealing focus.
        window.orderFrontRegardless()

        poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.refresh(force: false)
            self.dumpState()
        }
        cmdWatch = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            self.watchCommandFile()
        }
        refresh(force: true)
        dumpState()
        if ProcessInfo.processInfo.arguments.contains("--collapsed") {
            setCollapsed(true, animate: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

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
            "policy": NSApp.activationPolicy().rawValue,
            "hidden": NSApp.isHidden,
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
    func measureControls() {
        let js = "JSON.stringify(Array.from(document.querySelectorAll('button,#bubble,#drag')).map(e=>{const r=e.getBoundingClientRect();return {id:e.id,x:r.x,y:r.y,w:r.width,h:r.height}}))"
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
        if let s = defaults.string(forKey: "frame") {
            let r = NSRectFromString(s)
            if r.width > 40, r.height > 40, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                window.setFrame(r, display: false)
                collapsed = defaults.bool(forKey: "collapsed")
                applyShape(animate: false)
                return
            }
        }
        collapsed = defaults.bool(forKey: "collapsed")
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

    func setCollapsed(_ v: Bool, animate: Bool) {
        if collapsed == v {
            window.orderFrontRegardless()
            return
        }
        collapsed = v
        applyShape(animate: animate)
        window.orderFrontRegardless()
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
            setCollapsed(false, animate: true)
            window.orderFrontRegardless()
        case "dock": dockSide()
        case "state": dumpState()
        case "rect": measureControls()
        case "close": NSApp.terminate(nil)
        case "refresh": refresh(force: true)
        case "copy": copySummary()
        case "hop": runCommand("hop")
        case "doctor": runCommand("doctor")
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
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
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

        let path = scripts.appendingPathComponent(which == "hop" ? "zen-hop.sh" : "doctor.sh").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/local/bin:/opt/homebrew/bin:\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["TERM"] = "dumb"
        env["OUC_OVERLAY"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()

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
        case "expand": setCollapsed(false, animate: true)
        case "collapse": setCollapsed(true, animate: true)
        case "hop": runCommand("hop")
        case "doctor": runCommand("doctor")
        case "dock": dockSide()
        case "state": dumpState()
        case "rect": measureControls()
        case "snapshot": snapshot(to: cmdFile.deletingLastPathComponent().appendingPathComponent("overlay-snapshot.png"))
        case "probe":
            web.evaluateJavaScript("JSON.stringify({title:document.title,nodes:document.querySelectorAll('*').length,txt:document.body.innerText.slice(0,200)})") { v, e in
                let s = (v as? String) ?? "err: \(String(describing: e))"
                try? s.write(to: cmdFile.deletingLastPathComponent().appendingPathComponent("overlay-probe.txt"), atomically: true, encoding: .utf8)
            }
        case "close": NSApp.terminate(nil)
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
        refresh(force: true)
    }

    func webView(_ webView: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        NSLog("overlay load failed: \(e)")
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
