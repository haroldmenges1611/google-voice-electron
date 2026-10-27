// A floating "liquid glass" control with Back, Forward, Home and Reload. It sits over the page
// (bottom centre), is slightly faded until the pointer is over it, and always visible.

import Cocoa

final class FloatingNav: NSView {
    private let backButton: NSButton
    private let forwardButton: NSButton
    private var tracking: NSTrackingArea?

    private static let buttonSize: CGFloat = 46
    private static let barHeight: CGFloat = 58

    init(target: AnyObject, back: Selector, forward: Selector, home: Selector, reload: Selector) {
        func make(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(config) ?? NSImage()
            let button = NSButton(image: image, target: target, action: action)
            button.isBordered = false
            button.contentTintColor = .labelColor
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: FloatingNav.buttonSize).isActive = true
            button.heightAnchor.constraint(equalToConstant: FloatingNav.buttonSize).isActive = true
            return button
        }
        backButton = make("chevron.left", "Back", back)
        forwardButton = make("chevron.right", "Forward", forward)
        let homeButton = make("house", "Back to Voice", home)
        let reloadButton = make("arrow.clockwise", "Reload", reload)

        let width = 4 * FloatingNav.buttonSize + 3 * 4 + 24
        let frame = NSRect(x: 0, y: 0, width: width, height: FloatingNav.barHeight)
        super.init(frame: frame)

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
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = FloatingNav.barHeight / 2
            blur.layer?.masksToBounds = true
            blur.autoresizingMask = [.width, .height]
            blur.addSubview(stack)
            addSubview(blur)
        }

        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        alphaValue = 0.75
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Back and Forward dim when there is nowhere to go.
    func update(canBack: Bool, canForward: Bool) {
        backButton.isEnabled = canBack
        forwardButton.isEnabled = canForward
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = tracking { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.75 }
}
