import AppKit
import Combine
import CoreGraphics
import MeetMeetCore
import Observation
import SwiftUI

@MainActor
final class CountdownHUDController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let session: CalendarSession
    private let placement: HUDPlacementSession
    private let model: HUDViewModel
    private let panel: CountdownPanel
    private let content: HUDInteractionView
    private var reveal = HUDRevealState()
    private var revealTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var running = false
    private var observationGeneration = 0
    private var currentLayout: HUDLayout?
    private let revealOrigin = ContinuousClock().now
    private var layoutMoveDepth = 0

    var positionError: String? { placement.positionError }

    /// Only cue-time visible rows participate. Never reveal or retain a row for an alert.
    func showCueWiggles(for occurrences: [OccurrenceKey]) {
        guard running, panel.isVisible else { return }
        let previouslyVisible = Set(model.rows.map(\.id))
        synchronize()
        let visible = Set(model.rows.map(\.id)).intersection(previouslyVisible)
        for occurrence in Set(occurrences).intersection(visible) {
            model.cueWiggles[occurrence] = UUID()
        }
    }

    func cueWiggleToken(for occurrence: OccurrenceKey) -> UUID? { model.cueWiggles[occurrence] }

    private var revealNow: TimeInterval {
        let elapsed = revealOrigin.duration(to: ContinuousClock().now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    init(state: AppState, session: CalendarSession) {
        self.state = state
        self.session = session
        let placement = HUDPlacementSession(state: state)
        self.placement = placement
        let model = HUDViewModel(placement: placement)
        self.model = model
        let panel = CountdownPanel(contentRect: NSRect(x: 0, y: 0, width: 145, height: 58),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        let content = HUDInteractionView(model: model)
        self.content = content
        super.init()
        panel.delegate = self
        panel.contentView = content
        panel.identifier = NSUserInterfaceItemIdentifier("meetmeet.countdownHUD")
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.setAccessibilityLabel("Meeting countdowns")
        content.hoverChanged = { [weak self] hovering in self?.hoverChanged(hovering) }
        content.dragBegan = { [weak self] in self?.beginViewDrag() }
        content.dragEnded = { [weak self] in self?.endViewDrag() }
    }

    func start() {
        guard !running else { return }
        running = true
        observationGeneration += 1
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.synchronize() }
            .store(in: &observers)
        observe(observationGeneration)
    }

    func stop() {
        running = false
        observationGeneration += 1
        observers.removeAll()
        revealTask?.cancel()
        revealTask = nil
        model.rows = []
        model.cueWiggles = [:]
        model.expanded = false
        reveal = HUDRevealState()
        currentLayout = nil
        placement.resetMovement()
        panel.orderOut(nil)
    }

    private func observe(_ token: Int) {
        withObservationTracking {
            _ = session.presentation.hudRows
            _ = state.hudPosition
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running, self.observationGeneration == token else { return }
                self.observe(token)
            }
        }
        synchronize()
    }

    private func synchronize() {
        guard running else { return }
        let rows = session.presentation.hudRows
        let previousDeadline = reveal.arrivalUntil
        reveal.update(visibleIDs: Set(rows.map(\.id)), at: revealNow)
        model.rows = rows
        let visible = Set(rows.map(\.id))
        model.cueWiggles = model.cueWiggles.filter { visible.contains($0.key) }
        if previousDeadline != reveal.arrivalUntil { scheduleRevealExpiry() }
        let scrollerWidth = NSScroller.preferredScrollerStyle == .legacy
            ? Double(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) : 0
        let update = placement.update(rowCount: rows.count, expanded: reveal.isExpanded(at: revealNow),
                                      longestCountdownLength: rows.map { $0.text.count }.max() ?? 4,
                                      displays: Self.displays(), legacyScrollerWidth: scrollerWidth,
                                      isPointerDown: NSEvent.pressedMouseButtons & 1 != 0)
        switch update {
        case .hidden:
            model.expanded = false
            panel.orderOut(nil)
        case let .unchanged(expanded):
            model.expanded = expanded
        case let .layout(layout, expanded):
            model.expanded = expanded
            applyLayout(layout)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        reveal.setHovering(hovering)
        synchronize()
    }

    private func scheduleRevealExpiry() {
        revealTask?.cancel()
        revealTask = nil
        guard let deadline = reveal.arrivalUntil else { return }
        let delay = deadline - revealNow
        guard delay > 0 else { return }
        revealTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.revealTask = nil
            self?.synchronize()
        }
    }

    private func applyLayout(_ layout: HUDLayout) {
        model.timerWidth = layout.timerWidth
        model.titleWidth = layout.titleWidth
        model.documentWidth = layout.documentSize.width
        if panel.frame != layout.frame {
            layoutMoveDepth += 1
            panel.setFrame(layout.frame, display: true)
            layoutMoveDepth -= 1
        }
        if currentLayout != layout {
            content.configure(layout: layout)
            currentLayout = layout
        }
        if !panel.isVisible {
            // Only initial/restored presentation is ordered; countdown ticks never
            // activate the app or continually raise an already visible panel.
            panel.orderFrontRegardless()
            let hovering = panel.frame.contains(NSEvent.mouseLocation)
            reveal.setHovering(hovering)
            if hovering && !model.expanded {
                synchronize()
            }
        }
    }

    func beginViewDrag() {
        guard running else { return }
        placement.beginMove(at: panel.frame, source: .view)
    }

    func endViewDrag() {
        guard running else { return }
        placement.endMove(at: panel.frame, displays: Self.displays(), isPointerDown: NSEvent.pressedMouseButtons & 1 != 0)
        reveal.setHovering(panel.frame.contains(NSEvent.mouseLocation))
        synchronize()
    }

    func windowWillMove(_ notification: Notification) {
        guard running, layoutMoveDepth == 0, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        placement.beginMove(at: panel.frame, source: .nativeWindow)
    }

    func windowDidMove(_ notification: Notification) {
        guard running, layoutMoveDepth == 0, panel.isVisible else { return }
        // Native window-manager movement can bypass or outlive view drag
        // callbacks. Capture the authoritative anchor before a clock refresh
        // can reapply an old one. Our own expansion/reflow moves are excluded.
        placement.recordMove(to: panel.frame, displays: Self.displays(), isPointerDown: NSEvent.pressedMouseButtons & 1 != 0)
    }

    private static func displays() -> [HUDDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            var id = "screen-\(index)"
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                id = number.stringValue
                if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
                    id = CFUUIDCreateString(nil, uuid) as String
                }
            }
            return HUDDisplay(id: id, workArea: screen.visibleFrame)
        }
    }
}

private final class CountdownPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
private final class HUDViewModel {
    private let placement: HUDPlacementSession

    init(placement: HUDPlacementSession) { self.placement = placement }

    var cueWiggles: [OccurrenceKey: UUID] = [:]
    var rows: [CountdownRow] = []
    var expanded = false
    var timerWidth = 82.0
    var titleWidth = 190.0
    var documentWidth = 145.0
    var positionError: String? { placement.positionError }
}

private struct CountdownRowsView: View {
    let model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                HStack(spacing: 12) {
                    if model.expanded {
                        Text(row.title)
                            .font(.system(size: 13))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(width: model.titleWidth, alignment: .leading)
                    }
                    cueIcon(for: row)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 23)
                        .accessibilityHidden(true)
                    Text(row.text)
                        .font(.system(size: 29, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: model.timerWidth, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .frame(width: model.documentWidth, height: HUDLayoutPolicy.rowHeight, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.title)
                .accessibilityValue(row.accessibilityValue)
                .accessibilityHint(model.positionError ?? "Drag the stack to move it. Meeting actions are in the calendar menu.")
            }
        }
        .frame(width: model.documentWidth, alignment: .topTrailing)
    }

    @ViewBuilder
    private func cueIcon(for row: CountdownRow) -> some View {
        if reduceMotion {
            Image(systemName: row.symbolName)
        } else {
            Image(systemName: row.symbolName)
                .symbolEffect(.pulse, options: .repeating, isActive: row.shouldPulse)
                .symbolEffect(.wiggle, options: .repeat(.periodic(5, delay: 1)), value: model.cueWiggles[row.id])
        }
    }
}

private struct HUDBackgroundView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if reduceTransparency { RoundedRectangle(cornerRadius: 16).fill(.background) }
            else { RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12)))
        .accessibilityHidden(true)
    }
}

/// Pointer capture guarantees whole-stack dragging even over SwiftUI content.
/// Wheel events and actual scroller controls still route to the native scroll view.
private final class HUDInteractionView: NSView {
    let scrollView = NSScrollView()
    private let background = NSHostingView(rootView: HUDBackgroundView())
    private let document: NSHostingView<CountdownRowsView>
    private var hoverTracking: NSTrackingArea?
    var hoverChanged: ((Bool) -> Void)?
    var dragBegan: (() -> Void)?
    var dragEnded: (() -> Void)?

    init(model: HUDViewModel) {
        document = NSHostingView(rootView: CountdownRowsView(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        background.sizingOptions = []
        document.sizingOptions = []
        document.isFlipped = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        addSubview(background)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { return nil }

    func configure(layout: HUDLayout) {
        background.frame = bounds
        scrollView.frame = bounds
        scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
        scrollView.hasVerticalScroller = layout.needsScrolling
        scrollView.tile()
        document.frame = CGRect(origin: .zero, size: layout.documentSize)
        let origin = scrollView.contentView.bounds.origin
        let y = min(max(0, origin.y), max(0, layout.documentSize.height - scrollView.contentSize.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        var ancestor: NSView? = target
        while let current = ancestor, current !== self {
            if current is NSScroller { return target }
            ancestor = current.superview
        }
        return self
    }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit serves this synchronous accessibility callback on the main
        // thread, but its legacy declaration is nonisolated. Keep the returned
        // non-Sendable AX object in this stack frame; never send it to a task.
        nonisolated(unsafe) var target: Any?
        MainActor.assumeIsolated { target = accessibilityTarget(at: point) }
        return target
    }

    @MainActor private func accessibilityTarget(at point: NSPoint) -> Any? {
        // Pointer capture for whole-stack dragging must not capture the
        // VoiceOver cursor. Accessibility points are bottom-left screen
        // coordinates; the hosting document resolves its actual SwiftUI rows.
        guard let window else { return super.accessibilityHitTest(point) }
        let windowPoint = window.convertPoint(fromScreen: point)
        guard bounds.contains(convert(windowPoint, from: nil)) else {
            return super.accessibilityHitTest(point)
        }
        if let scroller = scrollView.verticalScroller, !scroller.isHidden,
           scroller.bounds.contains(scroller.convert(windowPoint, from: nil)) {
            return scroller.accessibilityHitTest(point)
        }
        return document.accessibilityHitTest(point) ?? super.accessibilityHitTest(point)
    }

    // Route content drags explicitly; the window delegate also captures native
    // movements that bypass or outlive these callbacks.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragBegan?()
        NSCursor.closedHand.push()
        window?.performDrag(with: event)
        NSCursor.pop()
        dragEnded?()
    }

    override func scrollWheel(with event: NSEvent) { scrollView.scrollWheel(with: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
