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
    func addMeeting() {
        let now = Date()
        events.append(MeetingOccurrence(id: "native-fixture-\(events.count)", calendarID: "fixture", title: "Another fixture",
                                        start: now.addingTimeInterval(120), end: now.addingTimeInterval(600)))
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
    window.setFrameOrigin(NSPoint(x: initial.minX - 120, y: initial.minY - 80))
    let moved = window.frame
    for _ in 0..<3 {
        session.tick()
        try await Task.sleep(for: .milliseconds(10))
    }
    let actualAnchor = NSPoint(x: window.frame.maxX, y: window.frame.maxY)
    let movedAnchor = NSPoint(x: moved.maxX, y: moved.maxY)
    #expect(actualAnchor == movedAnchor)
    let saved = try #require(AppState(storage: storage).hudPosition)
    #expect(saved.topRightX == Double(moved.maxX))
    #expect(saved.topRightY == Double(moved.maxY))
    #expect(storage.writes == writesBeforeMove + 1)
}

@Test @MainActor
func nativeHUDLayoutChangesDoNotOverwriteThePreferredPosition() async throws {
    let application = NSApplication.shared
    let screen = try #require(NSScreen.screens.first)
    let storage = NativeHUDMemoryStore()
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["fixture"])
    let preferred = HUDPosition(topRightX: Double(screen.visibleFrame.minX + 160), topRightY: Double(screen.visibleFrame.maxY - 100))
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
    #expect(state.hudPosition == preferred)
    #expect(window.frame.minX == screen.visibleFrame.minX)
    await reader.addMeeting()
    await session.refresh()
    #expect(await waitForHUD { window.frame.height > originalHeight })
    #expect(state.hudPosition == preferred)
    #expect(storage.writes == writesBeforeLayout)
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
#endif
