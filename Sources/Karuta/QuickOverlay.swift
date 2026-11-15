import AppKit
import KarutaCore

/// CleanShot-style Quick Access Overlay: one card per capture, stacked in the bottom-left corner.
/// Hovering a card reveals Copy / Save and corner buttons (close, edit, pin); dragging it drops the
/// file anywhere; a horizontal swipe or the close button dismisses it. The hide button tucks the whole
/// stack behind the screen edge, leaving a small tab that brings it back.
@MainActor
final class QuickOverlay {
    /// The shot to edit, and whether it should open with the backdrop on (the card shows it already composed).
    var onEdit: ((Shot, Bool) -> Void)?
    var onPin: ((Shot, NSRect) -> Void)?

    private static let maxCards = 5
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 16

    private var cards: [OverlayCard] = []
    private var isStackHidden = false
    private var tab: StackTab?

    /// `original` is the capture before an automatic backdrop was added, so editing can still change it.
    func show(_ shot: Shot, original: Shot? = nil, on screen: NSScreen) {
        let card = OverlayCard(shot: shot, screen: screen)
        card.original = original
        card.onAction = { [weak self, weak card] action in
            guard let self, let card else { return }
            self.handle(action, for: card)
        }
        // New cards slide in from the screen edge at the bottom; older ones move up.
        card.setFrameOrigin(NSPoint(x: x(for: card, hidden: true, gap: 0), y: screen.visibleFrame.minY + Self.margin))
        card.alphaValue = 0
        card.orderFrontRegardless()
        cards.insert(card, at: 0)
        // A new capture always brings a hidden stack back.
        if isStackHidden { setStackHidden(false) }
        // Keep at most maxCards, and drop the oldest cards that would stack above the top of the screen.
        while let excess = cards.count > Self.maxCards ? cards.last : stack().overflow {
            remove(excess, animated: true)
        }
        layout(animated: true)
    }

    private func handle(_ action: OverlayCard.Action, for card: OverlayCard) {
        switch action {
        case .copy:
            Exporter.copy(card.shot)
            remove(card, animated: true)
        case .save:
            do {
                try Exporter.save(card.shot)
                remove(card, animated: true)
            } catch {
                Self.showSaveError(error)
            }
        case .saveAs:
            if Exporter.saveAs(card.shot) { remove(card, animated: true) }
        case .edit:
            remove(card, animated: false, remember: false)
            if let video = card.shot.video {
                NSWorkspace.shared.open(video) // QuickTime Player (or the default app) for trimming and playback
                return
            }
            onEdit?(card.original ?? card.shot, card.original != nil)
        case .pin:
            guard card.shot.video == nil else { return NSSound.beep() }
            remove(card, animated: false, remember: false)
            onPin?(card.shot, card.frame)
        case .saveAll:
            saveAll()
        case .closeAll:
            closeAll()
        case .close, .dropped:
            remove(card, animated: true)
        case .swiped:
            remove(card, animated: true, slideOut: true)
        case .hide:
            setStackHidden(true)
        }
    }

    // MARK: Whole stack (menu bar and global shortcuts)

    /// Tucks the stack away, or brings it back.
    func toggleHidden() {
        guard !cards.isEmpty else { return }
        setStackHidden(!isStackHidden)
    }

    /// Saves every card to the save folder and closes them; a card that fails stays.
    func saveAll() {
        var failure: Error?
        for card in cards.reversed() {
            do {
                try Exporter.save(card.shot)
                remove(card, animated: true)
            } catch {
                failure = error
            }
        }
        if let failure { Self.showSaveError(failure) }
    }

    func closeAll() {
        for card in cards.reversed() { remove(card, animated: true) }
    }

    /// Brings back the most recently closed card.
    func restoreClosed(on screen: NSScreen) -> Bool {
        guard let entry = ClosedShots.popLast() else { return false }
        show(entry.shot, original: entry.original, on: screen)
        return true
    }

    static func showSaveError(_ error: Error) {
        SaveErrorAlert.show(error)
    }

    /// Where a card sits: just inside its side of the screen, or (hidden) just past that edge.
    private func x(for card: OverlayCard, hidden: Bool, gap: CGFloat = 20) -> CGFloat {
        CardLayout.x(screenFrame: card.screenFrame, cardWidth: card.frame.width, onRight: card.onRight,
                     hidden: hidden, margin: Self.margin, gap: gap)
    }

    private func setStackHidden(_ hidden: Bool) {
        isStackHidden = hidden
        layout(animated: true)
        updateTab()
    }

    /// The tab sits on the newest card's screen edge (its side), at the middle of its stack.
    private func updateTab() {
        guard isStackHidden, let newest = cards.first else {
            tab?.orderOut(nil)
            tab = nil
            if cards.isEmpty { isStackHidden = false }
            return
        }
        let onScreen = cards.filter { $0.screenFrame == newest.screenFrame }
        let top = (onScreen.map(\.frame.maxY).max() ?? newest.frame.maxY)
        let bottom = newest.screenFrame.minY + Self.margin
        if let existing = self.tab, existing.onRight != newest.onRight {
            existing.orderOut(nil)
            self.tab = nil
        }
        let tab = self.tab ?? StackTab(onRight: newest.onRight) { [weak self] in self?.setStackHidden(false) }
        let size = tab.frame.size
        let x = newest.onRight ? newest.screenFrame.maxX - size.width : newest.screenFrame.minX
        tab.setFrameOrigin(NSPoint(x: x, y: ((top + bottom) / 2 - size.height / 2).rounded()))
        tab.setCount(cards.count)
        tab.orderFrontRegardless()
        self.tab = tab
    }

    /// `remember` keeps the shot for "最近閉じたものを戻す" (not when it moves on to the editor or a pin).
    private func remove(_ card: OverlayCard, animated: Bool, slideOut: Bool = false, remember: Bool = true) {
        guard cards.contains(where: { $0 === card }) else { return }
        cards.removeAll { $0 === card }
        // Recordings aren't kept: "restore" brings back images only.
        if remember, card.shot.video == nil { ClosedShots.add(card.shot, original: card.original) }
        if animated {
            var frame = card.frame
            if slideOut { frame.origin.x = x(for: card, hidden: true, gap: 0) }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                card.animator().alphaValue = 0
                card.animator().setFrame(frame, display: true)
            }, completionHandler: {
                card.orderOut(nil)
            })
        } else {
            card.orderOut(nil)
        }
        layout(animated: animated)
        updateTab()
    }

    /// The y of each card (newest at the bottom, per screen), and the oldest card on a screen whose stack
    /// no longer fits below that screen's top edge.
    private func stack() -> (y: [ObjectIdentifier: CGFloat], overflow: OverlayCard?) {
        var y: [ObjectIdentifier: CGFloat] = [:]
        var nextY: [String: CGFloat] = [:] // per screen and side, the next free y
        var overflow: OverlayCard?
        for card in cards {
            let key = "\(card.screenFrame.minX),\(card.screenFrame.minY),\(card.onRight)"
            let base = nextY[key] ?? card.screenFrame.minY + Self.margin
            y[ObjectIdentifier(card)] = base
            nextY[key] = base + card.frame.height + Self.spacing
            if base > card.screenFrame.minY + Self.margin, base + card.frame.height > card.screenFrame.maxY - Self.margin {
                overflow = cards.last { $0.screenFrame == card.screenFrame && $0.onRight == card.onRight }
            }
        }
        return (y, overflow)
    }

    private func layout(animated: Bool) {
        let y = stack().y
        let hidden = isStackHidden
        if !hidden { cards.forEach { $0.orderFrontRegardless() } }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = animated ? 0.25 : 0
            context.allowsImplicitAnimation = true
            for card in cards {
                let origin = NSPoint(x: x(for: card, hidden: hidden), y: y[ObjectIdentifier(card)] ?? 0)
                card.animator().setFrame(NSRect(origin: origin, size: card.frame.size), display: true)
                card.animator().alphaValue = hidden ? 0 : 1
            }
        }, completionHandler: { [weak self] in
            // Off-screen isn't enough: a display to the left would show them. Take them off screen entirely.
            // AppKit calls this on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.isStackHidden else { return }
                self.cards.forEach { $0.orderOut(nil) }
            }
        })
    }
}
