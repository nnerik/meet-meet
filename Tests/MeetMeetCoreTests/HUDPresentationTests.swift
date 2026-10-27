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
                       displays: [HUDDisplay] = [primaryHUDDisplay], scroller: Double = 0) throws -> HUDLayout {
    try #require(placement.layout(rowCount: rows, expanded: expanded, longestCountdownLength: characters,
                                  displays: displays, legacyScrollerWidth: scroller))
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
    #expect(placement.layout(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: []) == nil)
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
    #expect(placement.layout(rowCount: 0, expanded: true, longestCountdownLength: 4, displays: [primaryHUDDisplay]) == nil)
    #expect(placement.layout(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: []) == nil)
    let invalid = HUDDisplay(id: "invalid", workArea: CGRect(x: 0, y: 0, width: 0, height: 0))
    #expect(placement.layout(rowCount: 2, expanded: true, longestCountdownLength: 4, displays: [invalid]) == nil)
    #expect(state.hudPosition == preferred)
    #expect(storage.writes == writes)
    #expect(try placedHUD(placement).displayID == "primary")
    #expect(storage.writes == writes + 1)
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
