// The core package stays UI-free. Xcode additionally compiles the native
// controller into its test target for passive-window configuration checks.
#if !SWIFT_PACKAGE
import AppKit
import Foundation
import Testing
import MeetMeetCore

@MainActor
private final class NativeHUDMemoryStore: LocalStateStoring {
    private var records: [String: Data] = [:]
    private(set) var writes = 0
    init(records: [String: Data] = [:]) { self.records = records }
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writes += 1 }
}

private actor UnusedHUDCalendar: CalendarReading {
    func access() -> CalendarAccess { .notRequested }
    func requestAccess() -> CalendarAccess { .notRequested }
    func calendars() -> [CalendarDescriptor] { [] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] { [] }
}

private actor NativeHUDCalendarFixture: CalendarReading {
    var events: [MeetingOccurrence]
    init(count: Int) {
        let now = Date()
        events = (0..<count).map { index in
            MeetingOccurrence(id: "native-fixture-\(index)", calendarID: "fixture", title: "Native HUD fixture \(index + 1)",
                              start: now.addingTimeInterval(120), end: now.addingTimeInterval(600))
        }
    }
    func access() -> CalendarAccess { .fullAccess }
    func addMeeting(startsIn seconds: TimeInterval = 120) {
        let now = Date()
        events.append(MeetingOccurrence(id: "native-fixture-\(events.count)", calendarID: "fixture", title: "Another fixture",
                                        start: now.addingTimeInterval(seconds), end: now.addingTimeInterval(600)))
    }
    func requestAccess() -> CalendarAccess { .fullAccess }
    func calendars() -> [CalendarDescriptor] { [CalendarDescriptor(id: "fixture", title: "Fixture", sourceTitle: "Test")] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] { events }
}

@MainActor
private func waitForHUD(_ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if condition() { return true }
        do { try await Task.sleep(for: .milliseconds(10)) }
        catch { return false }
    }
    return condition()
}

@Test @MainActor
func nativeHUDCannotBecomeKeyOrMainAndConstructionDoesNotActivateIt() throws {
    let application = NSApplication.shared
    let previousKey = application.keyWindow
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let state = AppState(storage: NativeHUDMemoryStore())
    let session = CalendarSession(reader: UnusedHUDCalendar(), state: state)
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    #expect(!window.canBecomeKey)
    #expect(!window.canBecomeMain)
    #expect(!window.isVisible)
    #expect(application.keyWindow === previousKey)
    #expect(window.level == .floating)
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(!window.styleMask.contains(.titled))
    #expect(window.isMovableByWindowBackground)
    #expect(!window.isOpaque)
    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(window.collectionBehavior.contains(.canJoinAllApplications))
    let panel = try #require(window as? NSPanel)
    #expect(!panel.hidesOnDeactivate)
    let content = try #require(window.contentView)
    #expect(content.acceptsFirstMouse(for: nil))
    #expect(!content.mouseDownCanMoveWindow)
    let scrollView = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    #expect(!scrollView.drawsBackground)
    #expect(!scrollView.hasHorizontalScroller)
    #expect(scrollView.documentView?.isFlipped == true)
    controller.start()
    #expect(!window.isVisible)
    #expect(application.keyWindow === previousKey)
}

@Test @MainActor
func nativeHUDAppearsScrollsAndReactsToPauseWithoutTakingFocus() async throws {
    let application = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let state = AppState(storage: NativeHUDMemoryStore())
    try state.setSelectedCalendarIDs(["fixture"])
    let count = Int(ceil(screen.visibleFrame.height / HUDLayoutPolicy.rowHeight)) + 2
    let session = CalendarSession(reader: NativeHUDCalendarFixture(count: count), state: state)
    await session.refresh()
    let previousKey = application.keyWindow
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    #expect(window.isVisible)
    #expect(application.keyWindow === previousKey)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID)
    #expect(screen.visibleFrame.contains(window.frame))
    let content = try #require(window.contentView)
    let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
    #expect(scroll.hasVerticalScroller)
    #expect(try #require(scroll.documentView).frame.height > scroll.contentSize.height)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 30))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.origin.y > 0)
    try session.pauseForToday()
    #expect(await waitForHUD { !window.isVisible })
    try session.resume()
    #expect(await waitForHUD { window.isVisible })
    #expect(application.keyWindow === previousKey)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID)
}

@Test @MainActor
func nativeHUDNativeMoveKeepsPositionAcrossCountdownRefresh() async throws {
    let application = NSApplication.shared
    let storage = NativeHUDMemoryStore()
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["fixture"])
    let session = CalendarSession(reader: NativeHUDCalendarFixture(count: 1), state: state)
    await session.refresh()
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    let initial = window.frame
    let writesBeforeMove = storage.writes
    // Replay the native window-manager movement independently of view callbacks.
    // This emits the same window-move notification as a background/window drag.
    window.setFrameOrigin(NSPoint(x: initial.minX - 120, y: initial.minY + 80))
    let moved = window.frame
    for _ in 0..<3 {
        session.tick()
        try await Task.sleep(for: .milliseconds(10))
    }
    let actualAnchor = NSPoint(x: window.frame.maxX, y: window.frame.minY)
    let movedAnchor = NSPoint(x: moved.maxX, y: moved.minY)
    #expect(actualAnchor == movedAnchor)
    let saved = try #require(AppState(storage: storage).hudPosition)
    let displays = NSScreen.screens.enumerated().map { HUDDisplay(id: "test-\($0.offset)", workArea: $0.element.visibleFrame) }
    let expected = try #require(HUDLayoutPolicy.position(for: moved, displays: displays))
    #expect(saved.rightOffset == expected.rightOffset)
    #expect(saved.bottomOffset == expected.bottomOffset)
    #expect(storage.writes == writesBeforeMove + 1)
}

@Test @MainActor
func nativeHUDLayoutChangesDoNotOverwriteThePreferredPosition() async throws {
    let application = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let storage = NativeHUDMemoryStore()
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["fixture"])
    let preferred = HUDPosition(rightOffset: Double(screen.visibleFrame.width - 160), bottomOffset: 100)
    try state.setHUDPosition(preferred)
    let reader = NativeHUDCalendarFixture(count: 1)
    let session = CalendarSession(reader: reader, state: state)
    await session.refresh()
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    let writesBeforeLayout = storage.writes
    controller.start()
    let originalHeight = window.frame.height
    let originalBottom = window.frame.minY
    #expect(state.hudPosition == preferred)
    #expect(window.frame.minX == screen.visibleFrame.minX)
    await reader.addMeeting()
    await session.refresh()
    #expect(await waitForHUD { window.frame.height > originalHeight })
    #expect(window.frame.minY == originalBottom)
    #expect(state.hudPosition == preferred)
    #expect(storage.writes == writesBeforeLayout)
}

@Test @MainActor
func nativeHUDProtectedPlacementKeepsItsLiveAnchorAndReportsTheFailedSave() async throws {
    let application = NSApplication.shared
    let protected = Data(#"{"version":99,"value":{"savedBy":"a newer version"}}"#.utf8)
    let storage = NativeHUDMemoryStore(records: [AppStateRecord.hudPosition.storageKey: protected])
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["fixture"])
    let session = CalendarSession(reader: NativeHUDCalendarFixture(count: 1), state: state)
    await session.refresh()
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    let writes = storage.writes
    let initial = window.frame
    window.setFrameOrigin(NSPoint(x: initial.minX - 120, y: initial.minY + 80))
    let movedAnchor = NSPoint(x: window.frame.maxX, y: window.frame.minY)
    #expect(controller.positionError?.contains("Position could not be saved") == true)
    for _ in 0..<3 {
        session.tick()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(NSPoint(x: window.frame.maxX, y: window.frame.minY) == movedAnchor)
    #expect(controller.positionError?.contains("another app version") == true)
    #expect(state.hudPosition == nil)
    #expect(AppState(storage: storage).hudPosition == nil)
    #expect(storage.data(forKey: AppStateRecord.hudPosition.storageKey) == protected)
    #expect(storage.writes == writes)
}

@Test(arguments: [false, true]) @MainActor
func nativeHUDViewDragDefersReflowAndKeepsItsAuthoritativeAnchor(protectedRecord: Bool) async throws {
    let application = NSApplication.shared
    let protected = Data(#"{"version":99,"value":{"savedBy":"a newer version"}}"#.utf8)
    let storage = NativeHUDMemoryStore(records: protectedRecord ? [AppStateRecord.hudPosition.storageKey: protected] : [:])
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["fixture"])
    let reader = NativeHUDCalendarFixture(count: 1)
    let session = CalendarSession(reader: reader, state: state)
    await session.refresh()
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    let initial = window.frame
    let writes = storage.writes
    // Replay the same adapter callbacks used around performDrag, plus a real
    // window-move notification. This is not a physical pointer-drag check.
    controller.beginViewDrag()
    window.setFrameOrigin(NSPoint(x: initial.minX - 120, y: initial.minY + 80))
    let moved = window.frame
    await reader.addMeeting()
    await session.refresh()
    for _ in 0..<10 { await Task.yield() }
    #expect(session.presentation.hudRows.count == 2)
    #expect(window.frame == moved)
    controller.endViewDrag()
    #expect(await waitForHUD { window.frame.height > initial.height })
    for _ in 0..<3 {
        session.tick()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.frame.maxX == moved.maxX)
    #expect(window.frame.minY == moved.minY)
    #expect(storage.writes == writes + (protectedRecord ? 0 : 1))
    if protectedRecord {
        #expect(controller.positionError != nil)
        #expect(state.hudPosition == nil)
        #expect(storage.data(forKey: AppStateRecord.hudPosition.storageKey) == protected)
    } else {
        #expect(controller.positionError == nil)
        #expect(state.hudPosition != nil)
        #expect(AppState(storage: storage).hudPosition == state.hudPosition)
    }
}

@Test @MainActor
func nativeHUDCueWigglesOnlyCurrentlyVisibleRowsAndDoesNotRetriggerOnTicks() async throws {
    let application = NSApplication.shared
    let state = AppState(storage: NativeHUDMemoryStore())
    try state.setSelectedCalendarIDs(["fixture"])
    let session = CalendarSession(reader: NativeHUDCalendarFixture(count: 2), state: state)
    await session.refresh()
    let keys = session.presentation.hudRows.map(\.id)
    #expect(keys.count == 2)
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    let frame = window.frame
    let absent = OccurrenceKey(calendarID: "fixture", occurrenceID: "not-visible")
    controller.showCueWiggles(for: keys + [absent])
    let token = try #require(controller.cueWiggleToken(for: keys[0]))
    #expect(controller.cueWiggleToken(for: keys[1]) != nil)
    #expect(controller.cueWiggleToken(for: absent) == nil)
    #expect(window.frame == frame)
    session.tick()
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.cueWiggleToken(for: keys[0]) == token)
    try session.pauseForToday()
    #expect(await waitForHUD { !window.isVisible })
    #expect(controller.cueWiggleToken(for: keys[0]) == nil)
    controller.showCueWiggles(for: keys)
    #expect(controller.cueWiggleToken(for: keys[0]) == nil)
    #expect(!window.isVisible)
    try session.resume()
    #expect(await waitForHUD { window.isVisible })
    #expect(controller.cueWiggleToken(for: keys[0]) == nil)
}
@MainActor private final class SilentHUDSoundPlayer: SystemSoundPlaying {
    func play(named name: String, volume: Double) {}
}

@Test(arguments: [2, 30]) @MainActor
func nativeHUDColdLaunchWithNoMeetingsRespectsConfiguredLead(leadMinutes: Int) async throws {
    let application = NSApplication.shared
    let state = AppState(storage: NativeHUDMemoryStore())
    try state.setSelectedCalendarIDs(["fixture"])
    try state.updatePreferences { $0.hudLeadMinutes = leadMinutes }
    let reader = NativeHUDCalendarFixture(count: 0)
    let live = MeetingSession(reader: reader, state: state, player: SilentHUDSoundPlayer())
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: live.calendarSession)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    live.start()
    controller.start()
    defer { controller.stop(); live.stop(); window.close() }
    await live.refresh()
    #expect(await waitForHUD { live.calendarSession.status == .ready && !window.isVisible })
    for _ in 0..<3 {
        live.tick()
        try await Task.sleep(for: .milliseconds(20))
    }
    await reader.addMeeting(startsIn: 300)
    live.invalidate()
    await live.refresh()
    #expect(!live.menuBarState.text(titleLimit: 24, formatTime: { _ in "12:00" }).isEmpty)
    let shouldShowHUD = leadMinutes >= 5
    #expect(live.presentation.hudRows.count == (shouldShowHUD ? 1 : 0))
    #expect(await waitForHUD { window.isVisible == shouldShowHUD })
    if shouldShowHUD {
        #expect(NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) })
    }
}
@MainActor
private func hudAccessibilityDescriptions(from root: any NSObjectProtocol) -> [String] {
    var visited: Set<ObjectIdentifier> = []
    func visit(_ element: any NSObjectProtocol) -> [String] {
        guard visited.count < 200, visited.insert(ObjectIdentifier(element)).inserted else { return [] }
        // SwiftUI's bridged nodes implement the Objective-C accessibility
        // getters without declaring conformance to NSAccessibilityProtocol.
        func property(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }
        var descriptions: [String] = []
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityValueDescription"] {
            if let text = property(name) as? String { descriptions.append(text) }
        }
        for child in property("accessibilityChildren") as? [Any] ?? [] {
            if let object = child as? any NSObjectProtocol { descriptions += visit(object) }
        }
        if let app = element as? NSApplication {
            for window in app.accessibilityWindows() as? [NSObject] ?? [] { descriptions += visit(window) }
        }
        return descriptions
    }
    return visit(root)
}

@Test @MainActor
func nativeHUDExposesMeetingRowsInTheApplicationAccessibilityTree() async throws {
    let application = NSApplication.shared
    // Initialize SwiftUI's assistive-technology bridge in this test process
    // only; do not enable system VoiceOver or request Accessibility permission.
    // AppKit exposes this attribute only through its legacy attribute interface.
    let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    let wasEnhanced = application.accessibilityAttributeValue(enhancedUI)
    application.accessibilitySetValue(true, forAttribute: enhancedUI)
    defer { application.accessibilitySetValue(wasEnhanced, forAttribute: enhancedUI) }
    let state = AppState(storage: NativeHUDMemoryStore())
    try state.setSelectedCalendarIDs(["fixture"])
    let session = CalendarSession(reader: NativeHUDCalendarFixture(count: 1), state: state)
    await session.refresh()
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let controller = CountdownHUDController(state: state, session: session)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.countdownHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(await waitForHUD {
        hudAccessibilityDescriptions(from: application).contains("Native HUD fixture 1")
    })
    #expect(hudAccessibilityDescriptions(from: window).contains("Native HUD fixture 1"))
    #expect(hudAccessibilityDescriptions(from: window).contains("Starts in 2 minutes"))
    let hit = try #require(window.accessibilityHitTest(NSPoint(x: window.frame.midX, y: window.frame.midY)) as? any NSObjectProtocol)
    #expect(hudAccessibilityDescriptions(from: hit).contains("Native HUD fixture 1"))
    let hitLabel = hit.perform(NSSelectorFromString("accessibilityLabel"))?.takeUnretainedValue() as? String
    #expect(hitLabel == "Native HUD fixture 1", Comment(rawValue: "Pointer target: \(type(of: hit))"))
    let content = try #require(window.contentView)
    #expect(content.hitTest(NSPoint(x: content.bounds.midX, y: content.bounds.midY)) === content)
    let expandedWidth = window.frame.width
    let exit = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 0, pressure: 0))
    window.contentView?.mouseExited(with: exit)
    try await Task.sleep(for: .milliseconds(3_100))
    #expect(window.frame.width < expandedWidth)
    #expect(hudAccessibilityDescriptions(from: application).contains("Native HUD fixture 1"))
    #expect(hudAccessibilityDescriptions(from: window).contains("Native HUD fixture 1"))
    #expect(hudAccessibilityDescriptions(from: window).contains("Starts in 2 minutes"))
    let collapsedHit = try #require(window.accessibilityHitTest(NSPoint(x: window.frame.midX, y: window.frame.midY)) as? any NSObjectProtocol)
    let collapsedLabel = collapsedHit.perform(NSSelectorFromString("accessibilityLabel"))?.takeUnretainedValue() as? String
    #expect(collapsedLabel == "Native HUD fixture 1")
    #expect(!window.canBecomeKey)
}
@Test @MainActor
func nativeSplashIsCenteredPassiveThemeAwareAndDismissable() async throws {
    let application = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let state = AppState(storage: NativeHUDMemoryStore())
    try state.setSelectedCalendarIDs(["fixture"])
    let cues = SplashCueSession(state: state)
    let before = Set(application.windows.map { ObjectIdentifier($0) })
    let previousKey = application.keyWindow
    let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let controller = SplashHUDController(session: cues)
    let window = try #require(application.windows.first {
        !before.contains(ObjectIdentifier($0)) && $0.identifier?.rawValue == "meetmeet.splashHUD"
    })
    defer { controller.stop(); window.close() }
    controller.start()
    #expect(!window.isVisible)
    let now = Date()
    let meeting = MeetingOccurrence(id: "splash", calendarID: "fixture", title: "Splash fixture",
                                    start: now.addingTimeInterval(30), end: now.addingTimeInterval(600))
    cues.update(occurrences: [meeting], isActive: true, at: now)
    #expect(await waitForHUD { window.isVisible })
    #expect(application.keyWindow === previousKey)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostPID)
    #expect(!window.canBecomeMain)
    #expect(window.styleMask.contains(.nonactivatingPanel))
    // AppKit rounds fractional window origins/sizes to display pixels. On CI's
    // 1024-point display, the 60% size produces a half-point center difference.
    let pixel = 1 / screen.backingScaleFactor
    #expect(abs(window.frame.midX - screen.visibleFrame.midX) <= pixel)
    #expect(abs(window.frame.midY - screen.visibleFrame.midY) <= pixel)
    #expect(screen.visibleFrame.contains(window.frame))
    #expect(abs(window.frame.width - window.frame.height * 1.5) <= 2.5 * pixel)
    let content = try #require(window.contentView)
    let image = try #require(content.subviews.compactMap { $0 as? NSImageView }.first)
    #expect(content.hitTest(NSPoint(x: content.bounds.midX, y: content.bounds.midY)) === content)
    window.appearance = NSAppearance(named: .aqua)
    #expect(await waitForHUD { image.identifier?.rawValue == "billboard-light-mode" })
    #expect(image.image != nil)
    window.appearance = NSAppearance(named: .darkAqua)
    #expect(await waitForHUD { image.identifier?.rawValue == "billboard-dark-mode" })
    #expect(image.image != nil)
    let close = try #require(content.subviews.compactMap { $0 as? NSButton }.first)
    close.performClick(nil)
    #expect(!window.isVisible)
    cues.update(occurrences: [meeting], isActive: true, at: now)
    #expect(cues.meetings.isEmpty)

    let another = MeetingOccurrence(id: "another-splash", calendarID: "fixture", title: "Another splash",
                                    start: now.addingTimeInterval(30), end: now.addingTimeInterval(600))
    cues.update(occurrences: [another], isActive: true, at: now)
    #expect(await waitForHUD { window.isVisible })
    // Escape is handled by the panel after the user gives it keyboard focus.
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                              charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    window.keyDown(with: escape)
    #expect(!window.isVisible)
    #expect(state.dismissedSplashCues == [meeting.key, another.key])

    let final = MeetingOccurrence(id: "final-splash", calendarID: "fixture", title: "Final splash",
                                  start: now.addingTimeInterval(30), end: now.addingTimeInterval(600))
    cues.update(occurrences: [final], isActive: true, at: now)
    #expect(await waitForHUD { window.isVisible })
    cues.update(occurrences: [final], isActive: true, at: final.start)
    #expect(await waitForHUD { !window.isVisible })
}
#endif
