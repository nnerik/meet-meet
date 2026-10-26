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
