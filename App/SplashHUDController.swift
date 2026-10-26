import AppKit
import Combine
import MeetMeetCore
import Observation

/// Image-only reminder. Ordering never activates the app or takes keyboard focus.
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
        guard !session.meetings.isEmpty, let screen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        let area = screen.visibleFrame
        let width = min(720, area.width * 0.6, area.height * 0.6 * 1.5)
        let height = width / 1.5
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
    private let imageView = NSImageView()
    private let closeButton = NSButton()
    var dismiss: (() -> Void)?

    init(bundle: Bundle) {
        self.bundle = bundle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel("Meeting starts soon")
        addSubview(imageView)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss meeting cue")
        closeButton.bezelStyle = .circular
        closeButton.isBordered = true
        closeButton.target = self
        closeButton.action = #selector(closeSplash)
        closeButton.setAccessibilityLabel("Dismiss meeting cue")
        closeButton.toolTip = "Dismiss (Escape after clicking the splash)"
        addSubview(closeButton)
        updateImage()
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
        return target === closeButton ? target : self
    }

    override func cancelOperation(_ sender: Any?) { dismiss?() }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        closeButton.frame = NSRect(x: bounds.maxX - 42, y: bounds.maxY - 42, width: 30, height: 30)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    private func updateImage() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = dark ? "billboard-dark-mode" : "billboard-light-mode"
        imageView.identifier = NSUserInterfaceItemIdentifier(name)
        imageView.image = bundle.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    @objc private func closeSplash() { dismiss?() }
}
