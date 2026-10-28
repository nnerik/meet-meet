import AppKit
import Combine
import MeetMeetCore
import Observation

/// Ordering never activates the app or takes keyboard focus.
/// Clicking the artwork can give this nonactivating panel focus for Escape.
@MainActor
final class SplashHUDController: NSObject {
    private let session: SplashCueSession
    private let panel: SplashPanel
    private let artwork: SplashArtworkView
    private var running = false
    private var generation = 0
    private var screenObserver: AnyCancellable?

    init(session: SplashCueSession) {
        self.session = session
        panel = SplashPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        artwork = SplashArtworkView(bundle: Bundle(for: SplashHUDController.self))
        super.init()
        panel.identifier = NSUserInterfaceItemIdentifier("meetmeet.splashHUD")
        panel.contentView = artwork
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.setAccessibilityLabel("Meeting starts soon")
        panel.dismiss = { [weak self] in self?.dismiss() }
        artwork.dismiss = { [weak self] in self?.dismiss() }
    }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        screenObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.synchronize() }
        observe(generation)
    }

    func stop() {
        running = false
        generation += 1
        screenObserver = nil
        panel.orderOut(nil)
    }

    private func observe(_ token: Int) {
        withObservationTracking {
            _ = session.meetings
            _ = session.endMeetings
            _ = session.preferences
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.generation == token else { return }
                self.observe(token)
            }
        }
        synchronize()
    }

    private func synchronize() {
        guard running else { return }
        // NSScreen.main follows keyboard focus; screens.first is the primary display.
        guard !session.meetings.isEmpty || !session.endMeetings.isEmpty, let screen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let area = screen.visibleFrame
        let width = min(640, area.width * 0.8)
        artwork.update(start: session.meetings, end: session.endMeetings, preferences: session.preferences, width: width)
        let height = min(artwork.contentHeight, area.height * 0.8)
        panel.setAccessibilityLabel(session.meetings.isEmpty ? "Meeting ends soon" : "Meeting starts soon")
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                              width: width, height: height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        session.dismiss()
        panel.orderOut(nil)
    }
}

private final class SplashPanel: NSPanel {
    var dismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { dismiss?() }
        else { super.keyDown(with: event) }
    }
}

private final class SplashArtworkView: NSView {
    private let bundle: Bundle
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private lazy var stackWidth = stack.widthAnchor.constraint(equalToConstant: 0)
    private let closeButton = NSButton()
    private var start: [MeetingOccurrence] = []
    private var end: [MeetingOccurrence] = []
    private var preferences: AppPreferences?
    private var contentWidth: CGFloat = 0
    private var scrollToTop = false
    var contentHeight: CGFloat { stack.fittingSize.height + 44 }
    var dismiss: (() -> Void)?

    init(bundle: Bundle) {
        self.bundle = bundle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        updateBackground()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        addSubview(scrollView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stackWidth.isActive = true
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss meeting cue")
        closeButton.bezelStyle = .circular
        closeButton.isBordered = true
        closeButton.target = self
        closeButton.action = #selector(closeSplash)
        closeButton.setAccessibilityLabel("Dismiss meeting cue")
        closeButton.toolTip = "Dismiss (Escape after clicking the splash)"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { return nil }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        if target is NSButton || target is NSScroller { return target }
        return self
    }

    override func cancelOperation(_ sender: Any?) { dismiss?() }

    override func scrollWheel(with event: NSEvent) { scrollView.scrollWheel(with: event) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 40))
        closeButton.frame = NSRect(x: bounds.maxX - 42, y: bounds.maxY - 42, width: 30, height: 30)
        if scrollToTop {
            scrollToTop = false
            let y = stack.isFlipped ? 0 : max(0, stack.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func update(start: [MeetingOccurrence], end: [MeetingOccurrence], preferences: AppPreferences, width: CGFloat) {
        guard self.start != start || self.end != end || self.preferences != preferences || contentWidth != width else { return }
        self.start = start
        self.end = end
        self.preferences = preferences
        contentWidth = width
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        stackWidth.constant = width
        let availableWidth = width - 32
        for (meetings, isEnd) in [(start, false), (end, true)] where !meetings.isEmpty {
            let name = isEnd ? preferences.endSplashImage : preferences.startSplashImage
            let image = NSImageView()
            image.image = CueMedia.image(named: name, isEnd: isEnd, bundle: bundle)
            image.imageScaling = .scaleProportionallyUpOrDown
            image.identifier = NSUserInterfaceItemIdentifier(name ?? (isEnd ? "wrap-wrap" : "meet-meet"))
            image.setAccessibilityLabel(isEnd ? "Meeting ends soon" : "Meeting starts soon")
            stack.addArrangedSubview(image)
            let size = image.image?.size ?? NSSize(width: 600, height: 400)
            image.widthAnchor.constraint(equalToConstant: availableWidth).isActive = true
            image.heightAnchor.constraint(equalToConstant: min(340, availableWidth * size.height / max(1, size.width))).isActive = true
            if image.image == nil {
                addText("Cue image unavailable. Choose another image in Cues settings.", width: availableWidth)
            }
            for meeting in meetings {
                addText(meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled meeting" : meeting.title,
                        width: availableWidth, bold: true)
                if !isEnd {
                    if let location = meeting.location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        addText(MeetingText.displayLocation(location, shortenGoogleRoomNames: preferences.shortenGoogleRoomNames),
                                width: availableWidth)
                    }
                    if let url = meeting.meetingURL {
                        let button = MeetingLinkButton(url: url)
                        stack.addArrangedSubview(button)
                    }
                }
            }
        }
        stack.layoutSubtreeIfNeeded()
        scrollToTop = true
        needsLayout = true
    }

    private func addText(_ text: String, width: CGFloat, bold: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: 18) : .systemFont(ofSize: 14)
        label.preferredMaxLayoutWidth = width
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @objc private func closeSplash() { dismiss?() }
}

private final class MeetingLinkButton: NSButton {
    private let url: URL
    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        title = "Open meeting"
        bezelStyle = .rounded
        target = self
        action = #selector(openMeeting)
        toolTip = url.absoluteString
        setAccessibilityLabel("Open meeting in default app")
    }
    required init?(coder: NSCoder) { return nil }
    @objc private func openMeeting() {
        if !NSWorkspace.shared.open(url) {
            let alert = NSAlert()
            alert.messageText = "Could not open meeting"
            alert.informativeText = "No application could open this meeting link."
            alert.runModal()
        }
    }
}
