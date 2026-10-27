// Google Voice as a native macOS app (unofficial) on the system WebKit (WKWebView). No bundled browser:
// WebKit updates with macOS. Runs as a normal windowed app, or as a menu bar panel.

import Cocoa
import ServiceManagement
import UserNotifications
import WebKit

let homeURL = URL(string: "https://voice.google.com/")!
let windowSize = NSSize(width: 1100, height: 760)
let panelSize = NSSize(width: 780, height: 700)

// Off by default. Turn on with: defaults write local.googlevoice.native debugLog -bool true
// Appends to ~/Library/Logs/GoogleVoice.log, to see which request Google rejects.
func debugLog(_ text: String) {
    guard UserDefaults.standard.bool(forKey: "debugLog") else { return }
    let line = "\(Date()) \(text)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoogleVoice.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

func isGoogleHost(_ host: String?) -> Bool {
    guard let host = host else { return false }
    return host == "google.com" || host.hasSuffix(".google.com")
}

func isAppURL(_ url: URL?) -> Bool {
    guard let url = url, url.scheme == "https" else { return false }
    return isGoogleHost(url.host)
}

// WKWebView has no Notification API. This gives the page one that forwards to the app.
let notificationShim = """
(() => {
  if (window.__gvNotificationShim) return;
  Object.defineProperty(window, '__gvNotificationShim', { value: true });
  const send = (title, options) => window.webkit.messageHandlers.notify.postMessage({
    title: String(title ?? ''),
    body: options && options.body ? String(options.body) : '',
  });
  class GVNotification {
    constructor(title, options) { send(title, options); this.title = String(title ?? ''); }
    close() {}
    addEventListener() {}
    removeEventListener() {}
    static get permission() { return 'granted'; }
    static requestPermission() { return Promise.resolve('granted'); }
  }
  Object.defineProperty(window, 'Notification', { value: GVNotification, writable: true, configurable: true });
  if (window.ServiceWorkerRegistration) {
    Object.defineProperty(ServiceWorkerRegistration.prototype, 'showNotification', {
      value(title, options) { send(title, options); return Promise.resolve(); },
      writable: true, configurable: true,
    });
  }
})();
"""

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate,
    WKUIDelegate, WKScriptMessageHandler, UNUserNotificationCenterDelegate
{
    var webView: WKWebView!
    var window: NSWindow?
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    let panelContainer = NSView(frame: NSRect(origin: .zero, size: panelSize))
    var clickMonitor: Any?
    var popupWindow: NSWindow?
    var popupWebView: WKWebView?
    var titleObservation: NSKeyValueObservation?
    var quitting = false
    var menuBarMode: Bool {
        get { UserDefaults.standard.string(forKey: "mode") == "menubar" }
        set { UserDefaults.standard.set(newValue ? "menubar" : "window", forKey: "mode") }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        makeWebView()
        let controller = NSViewController()
        controller.view = panelContainer
        popover.contentViewController = controller
        popover.contentSize = panelSize
        popover.behavior = .applicationDefined
        applyMode()
    }

    func makeWebView() {
        let config = WKWebViewConfiguration()
        // Makes WebKit's user agent look like Safari's, so Google's sign-in does not refuse the app.
        config.applicationNameForUserAgent = "Version/18.4 Safari/605.1.15"
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "notify")
        config.userContentController.addUserScript(
            WKUserScript(source: notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        titleObservation = webView.observe(\.title) { view, _ in
            // Google Voice puts the unread count in the title, e.g. "(3) Calls".
            let title = view.title ?? ""
            var badge = ""
            if title.hasPrefix("("), let end = title.firstIndex(of: ")") {
                badge = String(title[title.index(after: title.startIndex)..<end])
            }
            NSApp.dockTile.badgeLabel = Int(badge) != nil ? badge : nil
        }
        webView.load(URLRequest(url: homeURL))
    }

    // MARK: Modes

    func applyMode() {
        popupWindow?.close()
        buildMenus()
        if menuBarMode {
            NSApp.setActivationPolicy(.accessory)
            window?.orderOut(nil)
            installStatusItem()
            attach(to: panelContainer)
            showPopover()
        } else {
            removeStatusItem()
            NSApp.setActivationPolicy(.regular)
            showWindow()
        }
    }

    func attach(to host: NSView) {
        webView.removeFromSuperview()
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }

    func showWindow() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            win.title = "Dialtone"
            win.minSize = NSSize(width: 520, height: 480)
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))
            if !win.setFrameUsingName("GVMain") { win.center() }
            win.setFrameAutosaveName("GVMain")
            window = win
        }
        attach(to: window!.contentView!)
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    func showPanelOrWindow() {
        if menuBarMode { showPopover() } else { showWindow() }
    }

    // MARK: Menu bar

    func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let path = Bundle.main.path(forResource: "tray", ofType: "png"), let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 16, height: 16)
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.image = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "Dialtone")
        }
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // Clicks outside the app close the panel (not while a sign-in pop-up is open).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popupWindow == nil, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    func removeStatusItem() {
        if popover.isShown { popover.performClose(nil) }
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem?.menu = trayMenu()
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        attach(to: panelContainer)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func trayMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Dialtone", action: #selector(showPanelAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(modeItem())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dialtone", action: #selector(quit), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Menus

    func modeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Menu Bar Mode", action: #selector(toggleMode), keyEquivalent: "")
        item.target = self
        item.state = menuBarMode ? .on : .off
        return item
    }

    func loginItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        item.target = self
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        return item
    }

    func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu(title: "Dialtone")
        app.addItem(withTitle: "About Dialtone", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(modeItem())
        app.addItem(loginItem())
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Dialtone", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        let quitItem = app.addItem(withTitle: "Quit Dialtone", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r").target = self
        view.addItem(.separator())
        view.addItem(withTitle: "Actual Size", action: #selector(zoomReset), keyEquivalent: "0").target = self
        view.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+").target = self
        view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc func toggleMode() {
        menuBarMode.toggle()
        applyMode()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Open at Login failed: \(error)")
        }
        buildMenus()
    }

    @objc func showPanelAction() { showPanelOrWindow() }
    @objc func reload() { webView.reload() }
    @objc func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc func zoomReset() { webView.pageZoom = 1 }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: App lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanelOrWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { quitting = true }

    // Closing the main window keeps the app running so texts still arrive. Cmd-Q quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window && !quitting {
            sender.orderOut(nil)
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === popupWindow {
            popupWindow = nil
            popupWebView = nil
        }
    }

    // MARK: Notifications

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "notify", isAppURL(message.frameInfo.request.url),
              let body = message.body as? [String: Any] else { return }
        let title = String(((body["title"] as? String) ?? "").prefix(200))
        let text = String(((body["body"] as? String) ?? "").prefix(1000))
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Dialtone" : title
        content.body = text
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        showPanelOrWindow()
        handler()
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        debugLog("nav \(action.targetFrame == nil ? "popup" : (action.targetFrame!.isMainFrame ? "main" : "sub")) \(action.request.httpMethod ?? "?") \(url?.absoluteString ?? "nil")")
        // Google's sign-in ends on the Google Account page; go back to Voice instead.
        if webView === self.webView, action.targetFrame?.isMainFrame == true, url?.host == "myaccount.google.com",
           url?.query?.contains("utm_source=sign_in_no_continue") == true {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: homeURL))
            return
        }
        let inApp = action.targetFrame?.isMainFrame == false || url == nil || isAppURL(url)
            || ["about", "blob", "data"].contains(url?.scheme ?? "")
        if inApp {
            decisionHandler(.allow)
        } else {
            if let url = url, ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse, response.isForMainFrame {
            debugLog("response \(http.statusCode) \(http.url?.absoluteString ?? "nil")")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        debugLog("failed \(error.localizedDescription)")
    }

    // MARK: Pop-ups (sign-in, call window): only one at a time

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url
        let blank = url == nil || url?.absoluteString == "about:blank"
        debugLog("popup requested \(url?.absoluteString ?? "nil")")
        guard blank || isAppURL(url) else {
            if let url = url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            return nil
        }
        // A link to Voice from another Google page (for example the app launcher) opens in the main view.
        if !blank, url?.host == "voice.google.com", webView === self.webView, self.webView.url?.host != "voice.google.com" {
            self.webView.load(action.request)
            return nil
        }
        if let existing = popupWebView {
            if !blank {
                existing.load(action.request)
                popupWindow?.makeKeyAndOrderFront(nil)
                return nil
            }
            popupWindow?.close() // a script-driven pop-up needs a fresh window it can talk to
        }
        let view = WKWebView(frame: NSRect(origin: .zero, size: panelSize), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = view
        win.delegate = self
        win.level = .floating // stays in front of the menu bar panel
        win.center()
        win.makeKeyAndOrderFront(nil)
        popupWindow = win
        popupWebView = view
        return view
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView { popupWindow?.close() }
    }

    // MARK: Permissions and page dialogs

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "https" && isGoogleHost(origin.host) ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
