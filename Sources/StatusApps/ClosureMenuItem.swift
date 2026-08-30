import AppKit

/// An `NSMenuItem` that carries its own action, so the menu can be rebuilt from data on every
/// refresh without the delegate maintaining selector plumbing for rows that come and go.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not supported")
    }

    @objc private func invoke() {
        handler()
    }
}

extension NSMenuItem {
    /// A non-interactive row used for headers and readouts.
    static func label(_ title: String, monospaced: Bool = true, color: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        var attributes: [NSAttributedString.Key: Any] = [:]
        if monospaced {
            attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        attributes[.foregroundColor] = color ?? NSColor.secondaryLabelColor
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        return item
    }

    func monospaced() -> NSMenuItem {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        )
        return self
    }
}
