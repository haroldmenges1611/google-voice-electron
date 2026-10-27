// A floating "liquid glass" control with Back, Forward, Home and Reload. It lives in its own small
// window floating above the page (bottom centre), so a click on it never reaches the page behind.

import Cocoa
import WebKit

final class FloatingNav: NSView {
    private weak var webView: WKWebView?
    private let onHome: () -> Void
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var tracking: NSTrackingArea?

    private static let buttonSize: CGFloat = 46
    private static let barHeight: CGFloat = 58

    init(webView: WKWebView, onHome: @escaping () -> Void) {
        self.webView = webView
        self.onHome = onHome
        let width = 4 * FloatingNav.buttonSize + 3 * 4 + 24
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: FloatingNav.barHeight))

        backButton = make("chevron.left", "Back", #selector(goBack))
        forwardButton = make("chevron.right", "Forward", #selector(goForward))
        let homeButton = make("house", "Back to Voice", #selector(goHome))
        let reloadButton = make("arrow.clockwise", "Reload", #selector(reload))

        let stack = NSStackView(views: [backButton, forwardButton, homeButton, reloadButton])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = FloatingNav.barHeight / 2
            glass.contentView = stack
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
        } else {
            let blur = NSVisualEffectView(frame: bounds)
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = FloatingNav.barHeight / 2
            blur.layer?.masksToBounds = true
            blur.autoresizingMask = [.width, .height]
            blur.addSubview(stack)
            addSubview(blur)
        }
        alphaValue = 0.8
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func make(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: FloatingNav.buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: FloatingNav.buttonSize).isActive = true
        return button
    }

    @objc private func goBack() { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func goHome() { onHome() }
    @objc private func reload() { webView?.reload() }

    /// Back and Forward dim when there is nowhere to go.
    func update(canBack: Bool, canForward: Bool) {
        backButton.isEnabled = canBack
        forwardButton.isEnabled = canForward
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = tracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.8 }
}

/// A small non-activating window: it takes clicks without taking focus from the window it floats over.
private final class NavPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the control and keeps it centred at the bottom of whichever window it is attached to.
final class NavController {
    let nav: FloatingNav
    private let panel: NavPanel
    private weak var parent: NSWindow?
    private var observer: NSObjectProtocol?

    init(webView: WKWebView, onHome: @escaping () -> Void) {
        nav = FloatingNav(webView: webView, onHome: onHome)
        panel = NavPanel(contentRect: nav.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = nav
    }

    func attach(to window: NSWindow) {
        detach()
        parent = window
        panel.level = window.level
        window.addChildWindow(panel, ordered: .above)
        reposition()
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in self?.reposition() }
    }

    func detach() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent = nil
    }

    private func reposition() {
        guard let frame = parent?.frame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 18))
    }
}
