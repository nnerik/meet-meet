import CoreGraphics
import Foundation
import Testing
@testable import MeetMeetCore

private let hudNow = 1_000.0
private let firstHUDKey = OccurrenceKey(calendarID: "work", occurrenceID: "first")
private let secondHUDKey = OccurrenceKey(calendarID: "work", occurrenceID: "second")
private let primaryHUDDisplay = HUDDisplay(id: "primary", workArea: CGRect(x: 0, y: 0, width: 1_440, height: 900))
private let secondaryHUDDisplay = HUDDisplay(id: "secondary", workArea: CGRect(x: -1_280, y: 100, width: 1_280, height: 800))

private func hudLayout(rows: Int = 2, expanded: Bool = false, characters: Int = 4, position: HUDPosition? = nil,
                       displays: [HUDDisplay] = [primaryHUDDisplay], scroller: Double = 0) throws -> HUDLayout {
    try #require(HUDLayoutPolicy.layout(rowCount: rows, expanded: expanded, longestCountdownLength: characters,
                                       preferredPosition: position, displays: displays, legacyScrollerWidth: scroller))
}

@MainActor
private final class HUDPlacementStore: LocalStateStoring {
    var records: [String: Data] = [:]
    private(set) var writes = 0
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writes += 1 }
}

@MainActor
private func placedHUD(_ placement: HUDPlacementSession, rows: Int = 2, expanded: Bool = false, characters: Int = 4,
                       displays: [HUDDisplay] = [primaryHUDDisplay], scroller: Double = 0, pointerDown: Bool = false) throws -> HUDLayout {
    let update = placement.update(rowCount: rows, expanded: expanded, longestCountdownLength: characters,
                                  displays: displays, legacyScrollerWidth: scroller, isPointerDown: pointerDown)
    let layout: HUDLayout?
    if case let .layout(value, _) = update { layout = value }
    else { layout = nil }
    return try #require(layout)
}

@Test(arguments: [false, true]) @MainActor
func placementRecoveryPersistsTheCompactAnchorBeforeTemporaryExpansion(expanded: Bool) throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    try state.setHUDPosition(HUDPosition(rightOffset: 1_280, bottomOffset: 100, displayID: "unplugged"))
    let writes = storage.writes
    let placement = HUDPlacementSession(state: state)
    let recovered = try placedHUD(placement, expanded: expanded)
    let saved = HUDPosition(rightOffset: 1_280, bottomOffset: 100, displayID: "primary")
    #expect(state.hudPosition == saved)
    #expect(recovered.displayID == "primary")
    #expect(recovered.frame.minX == (expanded ? 0 : 15))
    #expect(storage.writes == writes + 1)
    #expect(placement.positionError == nil)
    let compact = try placedHUD(placement)
    #expect(compact.frame.maxX == 160)
    #expect(compact.frame.minY == 100)
    #expect(storage.writes == writes + 1)
    let restarted = HUDPlacementSession(state: AppState(storage: storage))
    #expect(try placedHUD(restarted).frame == compact.frame)
    #expect(storage.writes == writes + 1)
}

@Test @MainActor
func placementMigratesLegacyAnchorsBeforeExpansionAndSurvivesRestart() throws {
    let storage = HUDPlacementStore()
    storage.records[AppStateRecord.hudPosition.storageKey] = Data(#"{"version":1,"value":{"topRightX":-100,"topRightY":800,"displayID":"secondary"}}"#.utf8)
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    let expanded = try placedHUD(placement, rows: 1, expanded: true, displays: displays)
    #expect(expanded.frame.maxX == -100)
    #expect(expanded.frame.maxY == 800)
    #expect(state.hudPosition == HUDPosition(rightOffset: 100, bottomOffset: 642, displayID: "secondary"))
    #expect(storage.writes == 1)
    let restarted = HUDPlacementSession(state: AppState(storage: storage))
    #expect(try placedHUD(restarted, rows: 1, expanded: true, displays: displays).frame == expanded.frame)
    #expect(storage.writes == 1)
}

@Test @MainActor
func placementRetainsPreferredOffsetsThroughReflowClampingAndDisplayRelocation() throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    let preferred = HUDPosition(rightOffset: 40, bottomOffset: 700, displayID: "primary")
    try state.setHUDPosition(preferred)
    let writes = storage.writes
    let placement = HUDPlacementSession(state: state)
    let single = try placedHUD(placement, rows: 1)
    let tall = try placedHUD(placement, rows: 30, expanded: true, characters: 8, scroller: 15)
    #expect(tall.needsScrolling)
    #expect(tall.frame.minY < single.frame.minY)
    #expect(tall == (try hudLayout(rows: 30, expanded: true, characters: 8, position: preferred, scroller: 15)))
    #expect(state.hudPosition == preferred)
    #expect(try placedHUD(placement, rows: 1).frame == single.frame)
    #expect(storage.writes == writes)

    let relocated = HUDDisplay(id: "primary", workArea: CGRect(x: -500, y: -600, width: 1_000, height: 900))
    let layout = try placedHUD(placement, rows: 1, displays: [relocated])
    #expect(layout.frame.maxX == relocated.workArea.maxX - 40)
    #expect(layout.frame.minY == relocated.workArea.minY + 700)
    #expect(state.hudPosition == preferred)
    #expect(storage.writes == writes)
}

@Test @MainActor
func placementProtectedSaveKeepsLiveRecoveryWithoutChangingDurableState() throws {
    let storage = HUDPlacementStore()
    let protected = Data(#"{"version":99,"value":{"savedBy":"a newer version"}}"#.utf8)
    storage.records[AppStateRecord.hudPosition.storageKey] = protected
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    let moved = CGRect(x: -1_245, y: 300, width: 145, height: 116)
    placement.recordMove(to: moved, displays: displays)
    #expect(state.hudPosition == nil)
    #expect(placement.positionError?.contains("Position could not be saved") == true)
    #expect(try placedHUD(placement, displays: displays).frame == moved)

    // The saved display disappears while titles are expanded. Recovery must
    // preserve the compact right anchor even though expansion clamps leftward.
    let expanded = try placedHUD(placement, expanded: true)
    #expect(expanded.displayID == "primary")
    #expect(expanded.frame.minX == 0)
    #expect(expanded.frame.maxX == 347)
    let recovered = try placedHUD(placement)
    #expect(recovered.frame.maxX == 340)
    #expect(recovered.frame.minY == 200)
    for _ in 0..<3 {
        _ = try placedHUD(placement, rows: 5, expanded: true)
        #expect(try placedHUD(placement).frame == recovered.frame)
    }
    #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: []) == .hidden)
    #expect(try placedHUD(placement).frame == recovered.frame)
    #expect(placement.positionError != nil)
    #expect(state.hudPosition == nil)
    #expect(storage.records[AppStateRecord.hudPosition.storageKey] == protected)
    #expect(storage.writes == 0)

    let restartedState = AppState(storage: storage)
    let restarted = HUDPlacementSession(state: restartedState)
    let afterRestart = try placedHUD(restarted, displays: displays)
    #expect(afterRestart.displayID == "primary")
    #expect(afterRestart.frame.maxX == 1_416)
    #expect(afterRestart.frame.minY == 24)
    #expect(afterRestart.frame != recovered.frame)
    #expect(restartedState.hudPosition == nil)
    #expect(storage.records[AppStateRecord.hudPosition.storageKey] == protected)
    #expect(storage.writes == 0)
}

@Test @MainActor
func placementRecordsNativeAnchorsOnceAndRestoresTheirDisplayRelativeOffsets() throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    let moved = CGRect(x: -600, y: 300, width: 145, height: 116)
    placement.recordMove(to: moved, displays: displays)
    #expect(state.hudPosition == HUDPosition(rightOffset: 455, bottomOffset: 200, displayID: "secondary"))
    #expect(placement.positionError == nil)
    placement.recordMove(to: moved, displays: displays)
    #expect(storage.writes == 1)
    let restarted = HUDPlacementSession(state: AppState(storage: storage))
    #expect(try placedHUD(restarted, displays: displays).frame == moved)
    #expect(storage.writes == 1)
}

@Test @MainActor
func placementDefersRecoveryUntilRowsAndValidDisplaysAreAvailable() throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    let preferred = HUDPosition(rightOffset: 40, bottomOffset: 100, displayID: "unplugged")
    try state.setHUDPosition(preferred)
    let writes = storage.writes
    let placement = HUDPlacementSession(state: state)
    #expect(placement.update(rowCount: 0, expanded: true, longestCountdownLength: 4, displays: [primaryHUDDisplay]) == .hidden)
    #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: []) == .hidden)
    let invalid = HUDDisplay(id: "invalid", workArea: CGRect(x: 0, y: 0, width: 0, height: 0))
    #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: [invalid]) == .hidden)
    #expect(state.hudPosition == preferred)
    #expect(storage.writes == writes)
    #expect(try placedHUD(placement).displayID == "primary")
    #expect(storage.writes == writes + 1)
}

@Test(arguments: [HUDPlacementSession.MovementSource.view, .nativeWindow], [false, true]) @MainActor
func placementFreezesExpansionAndReflowUntilMovementFinishes(source: HUDPlacementSession.MovementSource, initiallyExpanded: Bool) throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    try state.setHUDPosition(HUDPosition(rightOffset: 400, bottomOffset: 100, displayID: "primary"))
    let placement = HUDPlacementSession(state: state)
    let initial = try placedHUD(placement, expanded: initiallyExpanded)
    placement.beginMove(at: initial.frame, source: source)
    let moved = initial.frame.offsetBy(dx: -50, dy: 80)
    placement.recordMove(to: moved, displays: [primaryHUDDisplay], isPointerDown: true)
    let writes = storage.writes
    for _ in 0..<3 {
        #expect(placement.update(rowCount: 5, expanded: !initiallyExpanded, longestCountdownLength: 8,
                                 displays: [primaryHUDDisplay], isPointerDown: true) == .unchanged(expanded: initiallyExpanded))
    }
    if source == .view { placement.endMove(at: moved, displays: [primaryHUDDisplay]) }
    // Native-only movement has no view completion; polling the released pointer
    // is sufficient. Both paths must now render the latest requested geometry.
    let after = try placedHUD(placement, rows: 5, expanded: !initiallyExpanded, characters: 8)
    #expect(after.frame.maxX == moved.maxX)
    #expect(after.frame.minY == moved.minY)
    #expect(after.frame.height == 290)
    #expect((after.titleWidth > 0) == !initiallyExpanded)
    #expect(storage.writes == writes)
    let restarted = HUDPlacementSession(state: AppState(storage: storage))
    let restored = try placedHUD(restarted)
    #expect(restored.frame.maxX == moved.maxX)
    #expect(restored.frame.minY == moved.minY)
}

@Test(arguments: [false, true]) @MainActor
func placementViewCompletionCapturesMovementWithoutNativeNotifications(didMove: Bool) throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let initial = try placedHUD(placement)
    placement.beginMove(at: initial.frame, source: .view)
    // A released pointer cannot retire a view interaction before its callback.
    #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4,
                             displays: [primaryHUDDisplay]) == .unchanged(expanded: false))
    let final = didMove ? initial.frame.offsetBy(dx: -120, dy: 80) : initial.frame
    placement.endMove(at: final, displays: [primaryHUDDisplay])
    let after = try placedHUD(placement, expanded: true)
    #expect(after.frame.maxX == final.maxX)
    #expect(after.frame.minY == final.minY)
    #expect(storage.writes == (didMove ? 1 : 0))
    #expect((state.hudPosition != nil) == didMove)
}

@Test @MainActor
func placementHandlesOverlappingCallbacksAndNativeMovementOutlivingTheView() throws {
    let storage = HUDPlacementStore()
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let initial = try placedHUD(placement)
    placement.beginMove(at: initial.frame, source: .nativeWindow)
    placement.beginMove(at: initial.frame, source: .view)
    let first = initial.frame.offsetBy(dx: -120, dy: 80)
    placement.recordMove(to: first, displays: [primaryHUDDisplay], isPointerDown: true)
    #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4,
                             displays: [primaryHUDDisplay]) == .unchanged(expanded: false))
    placement.endMove(at: first, displays: [primaryHUDDisplay], isPointerDown: true)
    let last = first.offsetBy(dx: -100, dy: 20)
    placement.recordMove(to: last, displays: [primaryHUDDisplay], isPointerDown: true)
    #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4,
                             displays: [primaryHUDDisplay], isPointerDown: true) == .unchanged(expanded: false))
    let after = try placedHUD(placement, expanded: true)
    #expect(after.frame.maxX == last.maxX)
    #expect(after.frame.minY == last.minY)
    #expect(after.titleWidth > 0)
    #expect(storage.writes == 2)
    // A late, duplicate completion cannot roll the authoritative anchor back.
    placement.endMove(at: first, displays: [primaryHUDDisplay])
    #expect(try placedHUD(placement).frame.maxX == last.maxX)
    #expect(storage.writes == 2)
}

@Test @MainActor
func placementCapturesNativeMovementWhenItsBeginNotificationIsMissing() throws {
    let storage = HUDPlacementStore()
    let placement = HUDPlacementSession(state: AppState(storage: storage))
    let initial = try placedHUD(placement, expanded: true)
    let moved = initial.frame.offsetBy(dx: -120, dy: 80)
    placement.recordMove(to: moved, displays: [primaryHUDDisplay], isPointerDown: true)
    #expect(placement.update(rowCount: 2, expanded: false, longestCountdownLength: 4,
                             displays: [primaryHUDDisplay], isPointerDown: true) == .unchanged(expanded: true))
    let released = try placedHUD(placement)
    #expect(released.frame.maxX == moved.maxX)
    #expect(released.frame.minY == moved.minY)
    #expect(released.titleWidth == 0)
    #expect(storage.writes == 1)
}

@Test(arguments: [false, true]) @MainActor
func placementDragRecoveryNeverCommitsTheExpandedRecoveryFrame(protectedRecord: Bool) throws {
    let storage = HUDPlacementStore()
    let protected = Data(#"{"version":99,"value":{"savedBy":"a newer version"}}"#.utf8)
    if protectedRecord { storage.records[AppStateRecord.hudPosition.storageKey] = protected }
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    let initial = try placedHUD(placement, expanded: true, displays: displays)
    placement.beginMove(at: initial.frame, source: .view)
    let moved = CGRect(x: -1_447, y: 300, width: 347, height: 116)
    placement.recordMove(to: moved, displays: displays, isPointerDown: true)
    #expect(placement.update(rowCount: 5, expanded: false, longestCountdownLength: 4,
                             displays: displays, isPointerDown: true) == .unchanged(expanded: true))
    #expect(placement.update(rowCount: 0, expanded: false, longestCountdownLength: 4,
                             displays: [primaryHUDDisplay], isPointerDown: true) == .hidden)

    // Display inputs change during the drag without a special caller flag.
    // Titles remain frozen, and the recovered expanded frame clamps leftward.
    let recovered = try placedHUD(placement, expanded: false, pointerDown: true)
    #expect(recovered.frame.minX == 0)
    #expect(recovered.frame.maxX == 347)
    #expect(recovered.titleWidth == 190)
    placement.endMove(at: recovered.frame, displays: [primaryHUDDisplay])
    let compact = try placedHUD(placement)
    #expect(compact.frame.maxX == 340)
    #expect(compact.frame.minY == 200)
    for _ in 0..<3 {
        _ = try placedHUD(placement, rows: 5, expanded: true)
        #expect(try placedHUD(placement).frame == compact.frame)
    }
    #expect(storage.writes == (protectedRecord ? 0 : 2))
    #expect((placement.positionError != nil) == protectedRecord)

    let durable = AppState(storage: storage)
    let restarted = HUDPlacementSession(state: durable)
    let restored = try placedHUD(restarted, displays: displays)
    if protectedRecord {
        #expect(durable.hudPosition == nil)
        #expect(restored.frame.maxX == 1_416)
        #expect(restored.frame.minY == 24)
        #expect(storage.records[AppStateRecord.hudPosition.storageKey] == protected)
    } else {
        #expect(durable.hudPosition == HUDPosition(rightOffset: 1_100, bottomOffset: 200, displayID: "primary"))
        #expect(restored.frame == compact.frame)
    }
}

@Test(arguments: [false, true]) @MainActor
func placementHidingPreservesPendingMovementWhileStoppingCancelsIt(hide: Bool) throws {
    let storage = HUDPlacementStore()
    let placement = HUDPlacementSession(state: AppState(storage: storage))
    let initial = try placedHUD(placement, expanded: true)
    placement.beginMove(at: initial.frame, source: .view)
    if hide {
        #expect(placement.update(rowCount: 0, expanded: true, longestCountdownLength: 4,
                                 displays: [primaryHUDDisplay]) == .hidden)
        #expect(placement.update(rowCount: 2, expanded: false, longestCountdownLength: 4,
                                 displays: [primaryHUDDisplay]) == .unchanged(expanded: true))
        placement.endMove(at: initial.frame, displays: [primaryHUDDisplay])
    } else { placement.resetMovement() }
    let restored = try placedHUD(placement)
    #expect(restored.titleWidth == 0)
    #expect(restored.frame.maxX == initial.frame.maxX)
    #expect(storage.writes == 0)
}

private enum RelocationNotificationOrder: CaseIterable, Equatable {
    case moveBeforeUpdate, repeatedMovesBeforeUpdate, moveAfterUpdate, completionBeforeUpdate, moveAndCompletionBeforeUpdate
    case moveAfterUnavailableDisplays
}

@Test(arguments: [false, true], RelocationNotificationOrder.allCases) @MainActor
private func placementRelocationNotificationBeforeDisplayUpdatePreservesCompactAnchor(protectedRecord: Bool, order: RelocationNotificationOrder) throws {
    let storage = HUDPlacementStore()
    let protected = Data(#"{"version":99,"value":{"savedBy":"a newer version"}}"#.utf8)
    if protectedRecord { storage.records[AppStateRecord.hudPosition.storageKey] = protected }
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    placement.recordMove(to: CGRect(x: -1_245, y: 300, width: 145, height: 116), displays: displays)
    let expanded = try placedHUD(placement, expanded: true, displays: displays)
    let hasCompletion = order == .completionBeforeUpdate || order == .moveAndCompletionBeforeUpdate
    if hasCompletion { placement.beginMove(at: expanded.frame, source: .view) }

    // macOS relocates the expanded window before the display-change update.
    // Its clamped right edge is not the preferred compact right edge.
    let relocated = CGRect(x: 0, y: 200, width: 347, height: 116)
    if order == .moveAfterUnavailableDisplays {
        #expect(placement.update(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: []) == .hidden)
    }
    if order == .moveAfterUpdate { _ = try placedHUD(placement, expanded: true) }
    if order != .completionBeforeUpdate { placement.recordMove(to: relocated, displays: [primaryHUDDisplay]) }
    if order == .repeatedMovesBeforeUpdate { placement.recordMove(to: relocated, displays: [primaryHUDDisplay]) }
    if hasCompletion { placement.endMove(at: relocated, displays: [primaryHUDDisplay]) }
    let compact = try placedHUD(placement)
    #expect(compact.frame.maxX == 340)
    #expect(compact.frame.minY == 200)
    if protectedRecord {
        #expect(state.hudPosition == nil)
        #expect(storage.records[AppStateRecord.hudPosition.storageKey] == protected)
        #expect(placement.positionError != nil)
    } else {
        #expect(state.hudPosition == HUDPosition(rightOffset: 1_100, bottomOffset: 200, displayID: "primary"))
    }
    #expect(storage.writes == (protectedRecord ? 0 : 2))

    // Once geometry is reconciled, genuine movement must still be accepted,
    // including a user returning to the previously rendered position.
    let userMoved = compact.frame.offsetBy(dx: 80, dy: 20)
    placement.recordMove(to: userMoved, displays: [primaryHUDDisplay], isPointerDown: true)
    #expect(try placedHUD(placement).frame == userMoved)
    placement.recordMove(to: compact.frame, displays: [primaryHUDDisplay])
    #expect(try placedHUD(placement).frame == compact.frame)
    let restarted = HUDPlacementSession(state: AppState(storage: storage))
    #expect(try placedHUD(restarted).frame.maxX == (protectedRecord ? 1_416 : 340))
    #expect(storage.writes == (protectedRecord ? 0 : 4))
}

@Test(arguments: [false, true]) @MainActor
func placementRelocationBeforeSameDisplayResizeUpdatePreservesOffsets(protectedRecord: Bool) throws {
    let storage = HUDPlacementStore()
    let protected = Data(#"{"version":99,"value":null}"#.utf8)
    if protectedRecord { storage.records[AppStateRecord.hudPosition.storageKey] = protected }
    let state = AppState(storage: storage)
    let placement = HUDPlacementSession(state: state)
    placement.recordMove(to: CGRect(x: 15, y: 100, width: 145, height: 116), displays: [primaryHUDDisplay])
    _ = try placedHUD(placement, expanded: true)
    let resized = HUDDisplay(id: "primary", workArea: CGRect(x: 200, y: 50, width: 1_620, height: 900))
    placement.recordMove(to: CGRect(x: 200, y: 150, width: 347, height: 116), displays: [resized])
    let compact = try placedHUD(placement, displays: [resized])
    #expect(compact.frame.maxX == 540)
    #expect(compact.frame.minY == 150)
    if protectedRecord {
        #expect(storage.records[AppStateRecord.hudPosition.storageKey] == protected)
        #expect(state.hudPosition == nil)
    } else {
        #expect(state.hudPosition == HUDPosition(rightOffset: 1_280, bottomOffset: 100, displayID: "primary"))
    }
}

@Test
func initialHUDUsesPrimaryUsableAreaAndBottomRightMargins() throws {
    let layout = try hudLayout()
    #expect(layout.frame.maxX == 1_416)
    #expect(layout.frame.minY == 24)
    #expect(layout.frame.width == 145)
    #expect(layout.frame.height == 116)
    #expect(layout.documentSize.height == 116)
    #expect(!layout.needsScrolling)
}

@Test
func expansionAnchorsTheRightEdgeAndCollapsesBackWithoutMovingTheSavedAnchor() throws {
    let position = HUDPosition(rightOffset: 440, bottomOffset: 100, displayID: "primary")
    let compact = try hudLayout(position: position)
    let expanded = try hudLayout(expanded: true, position: position)
    #expect(expanded.frame.maxX == compact.frame.maxX)
    #expect(expanded.frame.minY == compact.frame.minY)
    #expect(expanded.frame.width == 347)
    #expect(expanded.titleWidth == 190)
    #expect(try hudLayout(position: position).frame == compact.frame)
}

@Test
func leftEdgeExpansionShiftsTemporarilyRatherThanChangingPreference() throws {
    let position = HUDPosition(rightOffset: 1_280, bottomOffset: 100, displayID: "primary")
    let compact = try hudLayout(position: position)
    let expanded = try hudLayout(expanded: true, position: position)
    #expect(compact.frame.minX == 15)
    #expect(expanded.frame.minX == 0)
    #expect(expanded.frame.maxX == 347)
    #expect(try hudLayout(position: position).frame == compact.frame)
    #expect(!HUDLayoutPolicy.needsPositionRecovery(position, displays: [primaryHUDDisplay]))
}

@Test
func longCountdownsReceiveMoreWidthInsteadOfClippingTheTime() throws {
    let short = try hudLayout()
    let long = try hudLayout(characters: 8)
    #expect(long.timerWidth > short.timerWidth)
    #expect(long.frame.width > short.frame.width)
    #expect(long.frame.maxX == short.frame.maxX)
}

@Test
func manyRowsConstrainHeightAndRetainScrollableDocument() throws {
    let layout = try hudLayout(rows: 30, expanded: true)
    #expect(layout.needsScrolling)
    #expect(layout.frame.height == 852)
    #expect(layout.documentSize.height == 1_740)
    #expect(primaryHUDDisplay.workArea.contains(layout.frame))
    let legacy = try hudLayout(rows: 30, expanded: true, scroller: 15)
    #expect(legacy.frame.width == layout.frame.width + 15)
    #expect(legacy.documentSize.width == layout.documentSize.width)
}

@Test
func placementSupportsNegativeCoordinatesAndSavedDisplays() throws {
    let position = HUDPosition(rightOffset: 100, bottomOffset: 100, displayID: "secondary")
    let layout = try hudLayout(expanded: true, position: position, displays: [primaryHUDDisplay, secondaryHUDDisplay])
    #expect(layout.displayID == "secondary")
    #expect(layout.frame.maxX == -100)
    #expect(layout.frame.minY == 200)
    #expect(secondaryHUDDisplay.workArea.contains(layout.frame))
}

@Test
func missingDisplayRecoversToPrimaryEvenWhenCoordinatesOverlapAnotherDisplay() throws {
    let position = HUDPosition(rightOffset: 100, bottomOffset: 100, displayID: "unplugged")
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    #expect(HUDLayoutPolicy.needsPositionRecovery(position, displays: displays))
    let layout = try hudLayout(position: position, displays: displays)
    #expect(layout.displayID == "primary")
    #expect(primaryHUDDisplay.workArea.contains(layout.frame))
}

@Test
func resizedWorkAreaClampsOffscreenAnchorsAndAcceptsExactScreenEdges() throws {
    let position = HUDPosition(rightOffset: -4_000, bottomOffset: -1_000, displayID: "primary")
    #expect(HUDLayoutPolicy.needsPositionRecovery(position, displays: [primaryHUDDisplay]))
    #expect(primaryHUDDisplay.workArea.contains(try hudLayout(position: position).frame))
    let edge = HUDPosition(rightOffset: 0, bottomOffset: 0, displayID: "primary")
    #expect(!HUDLayoutPolicy.needsPositionRecovery(edge, displays: [primaryHUDDisplay]))
}

@Test
func unscopedLegacyPositionsUseTheDisplayContainingTheirAnchor() throws {
    let data = Data(#"{"topRightX":-100,"topRightY":800}"#.utf8)
    let position = try JSONDecoder().decode(HUDPosition.self, from: data)
    #expect(try hudLayout(position: position, displays: [primaryHUDDisplay, secondaryHUDDisplay]).displayID == "secondary")
    #expect(HUDLayoutPolicy.needsPositionRecovery(position, displays: [primaryHUDDisplay, secondaryHUDDisplay]))
}

@Test
func displayForDraggingUsesLargestIntersectionAndStablePrimaryTie() {
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    #expect(HUDLayoutPolicy.displayID(for: CGRect(x: -200, y: 400, width: 300, height: 100), displays: displays) == "secondary")
    #expect(HUDLayoutPolicy.displayID(for: CGRect(x: -150, y: 400, width: 300, height: 100), displays: displays) == "primary")
    #expect(HUDLayoutPolicy.displayID(for: CGRect(x: 9_000, y: 9_000, width: 300, height: 100), displays: displays) == "primary")
}

@Test
func unavailableOrInvalidDisplaysAndEmptyRowsDoNotProduceAWindow() {
    #expect(HUDLayoutPolicy.layout(rowCount: 0, expanded: false, longestCountdownLength: 4, preferredPosition: nil, displays: [primaryHUDDisplay]) == nil)
    #expect(HUDLayoutPolicy.layout(rowCount: 1, expanded: false, longestCountdownLength: 4, preferredPosition: nil, displays: []) == nil)
    let invalid = HUDDisplay(id: "bad", workArea: CGRect(x: 0, y: 0, width: -1, height: 0))
    #expect(HUDLayoutPolicy.layout(rowCount: 1, expanded: false, longestCountdownLength: 4, preferredPosition: nil, displays: [invalid]) == nil)
}

@Test
func nonfiniteSavedPositionFallsBackWithoutProducingInvalidFrames() throws {
    let position = HUDPosition(rightOffset: .nan, bottomOffset: .infinity, displayID: "primary")
    #expect(HUDLayoutPolicy.needsPositionRecovery(position, displays: [primaryHUDDisplay]))
    #expect(try hudLayout(position: position).frame == hudLayout().frame)
}

@Test
func smallUsableAreasStillContainTheWindow() throws {
    let tiny = HUDDisplay(id: "small", workArea: CGRect(x: 10, y: 20, width: 180, height: 150))
    let layout = try hudLayout(rows: 10, expanded: true, displays: [tiny])
    #expect(tiny.workArea.contains(layout.frame))
    #expect(layout.needsScrolling)
    #expect(layout.titleWidth >= 0)
    #expect(layout.timerWidth > 0)
}

@Test
func rowChangesGrowUpwardAndReturnToTheSameBottomRightAnchor() throws {
    let position = HUDPosition(rightOffset: 40, bottomOffset: 60, displayID: "primary")
    let single = try hudLayout(rows: 1, position: position)
    let stack = try hudLayout(rows: 5, position: position)
    #expect(stack.frame.minY == single.frame.minY)
    #expect(stack.frame.maxX == single.frame.maxX)
    #expect(stack.frame.maxY > single.frame.maxY)
    #expect(try hudLayout(rows: 1, position: position).frame == single.frame)
}

@Test
func savedOffsetsSurviveDisplayResizingAndRelocation() throws {
    let original = try hudLayout(position: HUDPosition(rightOffset: 80, bottomOffset: 70, displayID: "secondary"),
                                 displays: [primaryHUDDisplay, secondaryHUDDisplay])
    let saved = try #require(HUDLayoutPolicy.position(for: original.frame, displays: [primaryHUDDisplay, secondaryHUDDisplay]))
    let restored = try JSONDecoder().decode(HUDPosition.self, from: JSONEncoder().encode(saved))
    let resized = HUDDisplay(id: "secondary", workArea: CGRect(x: 200, y: -600, width: 1_000, height: 600))
    let layout = try hudLayout(position: restored, displays: [primaryHUDDisplay, resized])
    #expect(layout.displayID == "secondary")
    #expect(resized.workArea.maxX - layout.frame.maxX == 80)
    #expect(layout.frame.minY - resized.workArea.minY == 70)
    #expect(!HUDLayoutPolicy.needsPositionRecovery(restored, displays: [primaryHUDDisplay, resized]))
}

@Test
func heightClampingDoesNotChangeThePreferredBottomAnchor() throws {
    let position = HUDPosition(rightOffset: 40, bottomOffset: 700, displayID: "primary")
    let single = try hudLayout(rows: 1, position: position)
    let stack = try hudLayout(rows: 5, position: position)
    #expect(stack.frame.maxY == primaryHUDDisplay.workArea.maxY)
    #expect(stack.frame.minY < single.frame.minY)
    #expect(!HUDLayoutPolicy.needsPositionRecovery(position, displays: [primaryHUDDisplay]))
    #expect(try hudLayout(rows: 1, position: position).frame == single.frame)
}

@Test
func legacyAbsolutePositionsMigrateToDisplayRelativeBottomAnchors() throws {
    let data = Data(#"{"topRightX":-100,"topRightY":800,"displayID":"secondary"}"#.utf8)
    let legacy = try JSONDecoder().decode(HUDPosition.self, from: data)
    let displays = [primaryHUDDisplay, secondaryHUDDisplay]
    #expect(HUDLayoutPolicy.needsPositionRecovery(legacy, displays: displays))
    let layout = try hudLayout(rows: 1, position: legacy, displays: displays)
    #expect(layout.frame.maxX == -100)
    #expect(layout.frame.maxY == 800)
    let migrated = try #require(HUDLayoutPolicy.position(for: layout.frame, displays: displays))
    #expect(migrated.rightOffset == 100)
    #expect(migrated.bottomOffset == 642)
    #expect(!HUDLayoutPolicy.needsPositionRecovery(migrated, displays: displays))
    let encoded = try JSONEncoder().encode(migrated)
    let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(fields["topRightX"] == nil)
    #expect(fields["topRightY"] == nil)
    #expect(try hudLayout(rows: 1, position: migrated, displays: displays).frame == layout.frame)
}

@Test
func titleRevealLastsThreeSecondsAndHoverExtendsIt() {
    var reveal = HUDRevealState()
    reveal.update(visibleIDs: [firstHUDKey], at: hudNow)
    #expect(reveal.isExpanded(at: hudNow))
    #expect(reveal.isExpanded(at: hudNow + 2.999))
    #expect(!reveal.isExpanded(at: hudNow + 3))
    reveal.setHovering(true)
    #expect(reveal.isExpanded(at: hudNow + 10))
    reveal.setHovering(false)
    #expect(!reveal.isExpanded(at: hudNow + 10))
}

@Test
func reorderingTickingOrRemovingRowsDoesNotRestartTitleReveal() {
    var reveal = HUDRevealState()
    reveal.update(visibleIDs: [firstHUDKey, secondHUDKey], at: hudNow)
    let original = reveal.arrivalUntil
    reveal.update(visibleIDs: [secondHUDKey, firstHUDKey], at: hudNow + 2)
    reveal.update(visibleIDs: [secondHUDKey], at: hudNow + 4)
    #expect(reveal.arrivalUntil == original)
    #expect(!reveal.isExpanded(at: hudNow + 4))
}

@Test
func aNewOrRestoredRowRevealsAllTitlesAgain() {
    var reveal = HUDRevealState()
    reveal.update(visibleIDs: [firstHUDKey], at: hudNow)
    reveal.update(visibleIDs: [firstHUDKey, secondHUDKey], at: hudNow + 10)
    #expect(reveal.arrivalUntil == hudNow + 13)
    reveal.update(visibleIDs: [secondHUDKey], at: hudNow + 14)
    reveal.update(visibleIDs: [firstHUDKey, secondHUDKey], at: hudNow + 20)
    #expect(reveal.arrivalUntil == hudNow + 23)
}

@Test
func emptyRowsClearHoverAndPauseResumeCountsAsRestoration() {
    var reveal = HUDRevealState()
    reveal.update(visibleIDs: [firstHUDKey], at: hudNow)
    reveal.setHovering(true)
    reveal.update(visibleIDs: [], at: hudNow + 1)
    #expect(!reveal.isExpanded(at: hudNow + 1))
    #expect(reveal.arrivalUntil == nil)
    reveal.update(visibleIDs: [firstHUDKey], at: hudNow + 10)
    #expect(reveal.isExpanded(at: hudNow + 12))
    #expect(!reveal.isExpanded(at: hudNow + 13))
}
