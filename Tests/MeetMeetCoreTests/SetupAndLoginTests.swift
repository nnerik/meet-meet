import Foundation
import Testing
@testable import MeetMeetCore

#if !SWIFT_PACKAGE
import AppKit
import SwiftUI

private actor SetupCalendarFake: CalendarReading {
    private(set) var requests = 0
    func access() -> CalendarAccess { .denied }
    func requestAccess() -> CalendarAccess { requests += 1; return .denied }
    func calendars() -> [CalendarDescriptor] { [] }
    func occurrences(in interval: DateInterval, calendarIDs: Set<String>) -> [MeetingOccurrence] { [] }
}

@Test @MainActor func nativeSetupViewsRenderWithoutRequestingCalendarOrLoginAccess() async {
    _ = NSApplication.shared
    let state = AppState(storage: SetupMemoryStore())
    let reader = SetupCalendarFake()
    let session = CalendarSession(reader: reader, state: state)
    let setup = OnboardingSession(state: state)
    let service = LoginServiceFake()
    let login = LoginLaunchSession(service: service)
    for step in OnboardingStep.allCases {
        #expect(setup.step == step)
        let view = NSHostingView(rootView: OnboardingView(setup: setup, state: state, session: session, login: login))
        view.frame = NSRect(x: 0, y: 0, width: 580, height: 460)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width == 580)
        setup.next()
    }
    #expect(await reader.requests == 0)
    #expect(service.registrations == 0)
    #expect(service.removals == 0)
    #expect(!state.onboardingCompleted)
}
#endif

@MainActor private final class SetupMemoryStore: LocalStateStoring {
    var records: [String: Data] = [:]
    var writes = 0
    func data(forKey key: String) -> Data? { records[key] }
    func set(_ data: Data?, forKey key: String) { records[key] = data; writes += 1 }
}

@MainActor private final class LoginServiceFake: LoginLaunchServicing {
    var status = LoginLaunchStatus.off
    var afterRegistration = LoginLaunchStatus.enabled
    var registrations = 0
    var removals = 0
    var shouldFail = false
    var removalContinuation: CheckedContinuation<Void, Never>?
    var suspendRemoval = false

    func register() throws {
        registrations += 1
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        status = afterRegistration
    }

    func unregister() async throws {
        removals += 1
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        if suspendRemoval { await withCheckedContinuation { removalContinuation = $0 } }
        status = .off
    }
}

@Test @MainActor func freshOnboardingDoesNotChangePreferencesOrRequireCalendarSelection() {
    let storage = SetupMemoryStore()
    let state = AppState(storage: storage)
    let setup = OnboardingSession(state: state)
    #expect(setup.isPresented)
    #expect(setup.step == .welcome)
    setup.back()
    #expect(setup.step == .welcome)
    setup.next()
    #expect(setup.step == .calendars)
    setup.next()
    #expect(setup.step == .login)
    setup.next()
    #expect(setup.step == .login)
    #expect(storage.writes == 0)
    setup.finish()
    #expect(!setup.isPresented)
    #expect(state.onboardingCompleted)
    #expect(state.selectedCalendarIDs.isEmpty)
    #expect(state.preferences == AppPreferences())
    #expect(storage.records.count == 1)
    #expect(!OnboardingSession(state: AppState(storage: storage)).isPresented)
}

@Test @MainActor func interruptedAndManuallyReviewedOnboardingPreserveChoices() throws {
    let storage = SetupMemoryStore()
    let state = AppState(storage: storage)
    try state.setSelectedCalendarIDs(["existing"])
    try state.updatePreferences { $0.startCue.isEnabled = true; $0.hudLeadMinutes = 15 }
    let setup = OnboardingSession(state: state)
    setup.next()
    setup.next()
    setup.back()
    #expect(setup.step == .calendars)
    let reconstructed = OnboardingSession(state: AppState(storage: storage))
    #expect(reconstructed.isPresented)
    #expect(reconstructed.step == .welcome)
    setup.finish()
    let writesAfterFinish = storage.writes
    setup.present()
    #expect(setup.isPresented)
    #expect(setup.step == .welcome)
    #expect(storage.writes == writesAfterFinish)
    #expect(!OnboardingSession(state: AppState(storage: storage)).isPresented)
    #expect(state.selectedCalendarIDs == ["existing"])
    #expect(state.preferences.startCue.isEnabled)
    #expect(state.preferences.hudLeadMinutes == 15)
}

@Test @MainActor func unreadableOnboardingRecordsDoNotMasqueradeAsFirstLaunch() {
    for data in [Data("corrupt".utf8), Data(#"{"version":99,"value":true}"#.utf8)] {
        let storage = SetupMemoryStore()
        storage.records[AppStateRecord.onboarding.storageKey] = data
        let state = AppState(storage: storage)
        let setup = OnboardingSession(state: state)
        #expect(!setup.isPresented)
        #expect(storage.writes == 0)
        #expect(storage.records[AppStateRecord.onboarding.storageKey] == data)
    }
}

@Test @MainActor func protectedSetupCompletionFailureKeepsSetupOpenAndPreservesRecord() {
    let storage = SetupMemoryStore()
    let data = Data(#"{"version":99,"value":true}"#.utf8)
    storage.records[AppStateRecord.onboarding.storageKey] = data
    let setup = OnboardingSession(state: AppState(storage: storage))
    setup.present()
    setup.finish()
    #expect(setup.isPresented)
    #expect(setup.errorMessage != nil)
    #expect(storage.writes == 0)
    #expect(storage.records[AppStateRecord.onboarding.storageKey] == data)
}

@Test @MainActor func loginStatusRefreshNeverRegistersOrWritesASeparatePreference() {
    let service = LoginServiceFake()
    let login = LoginLaunchSession(service: service)
    #expect(login.status == .off)
    #expect(!login.status.isRequested)
    for status in [LoginLaunchStatus.enabled, .requiresApproval, .off, .unavailable, .unknown] {
        service.status = status
        login.refresh()
        #expect(login.status == status)
        #expect(!login.status.description.isEmpty)
    }
    #expect(service.registrations == 0)
    #expect(service.removals == 0)
}

@Test @MainActor func loginOptInUsesActualApprovalStatusAndCanCancelPendingRequest() async {
    let service = LoginServiceFake()
    service.afterRegistration = .requiresApproval
    let login = LoginLaunchSession(service: service)
    await login.setEnabled(true)
    #expect(login.status == .requiresApproval)
    #expect(login.status.isRequested)
    #expect(service.registrations == 1)
    await login.setEnabled(true)
    #expect(service.registrations == 1)
    await login.setEnabled(false)
    #expect(login.status == .off)
    #expect(service.removals == 1)
    #expect(!login.isChanging)
}

@Test @MainActor func loginRegistrationAndRemovalErrorsRetainActualState() async {
    let service = LoginServiceFake()
    let login = LoginLaunchSession(service: service)
    service.shouldFail = true
    await login.setEnabled(true)
    #expect(login.status == .off)
    #expect(login.errorMessage != nil)
    #expect(!login.isChanging)
    service.shouldFail = false
    await login.setEnabled(true)
    #expect(login.status == .enabled)
    #expect(login.errorMessage == nil)
    service.shouldFail = true
    await login.setEnabled(false)
    #expect(login.status == .enabled)
    #expect(login.errorMessage != nil)
    #expect(!login.isChanging)
}

@Test @MainActor func loginSerializesPendingChangesAndRefreshesAfterExternalApproval() async {
    let service = LoginServiceFake()
    service.status = .requiresApproval
    service.suspendRemoval = true
    let login = LoginLaunchSession(service: service)
    let task = Task { await login.setEnabled(false) }
    // Yield until the fake service has entered its suspended removal operation.
    for _ in 0..<100 where service.removalContinuation == nil { await Task.yield() }
    let continuation = service.removalContinuation
    #expect(continuation != nil)
    #expect(login.isChanging)
    await login.setEnabled(true)
    #expect(service.registrations == 0)
    continuation?.resume()
    await task.value
    #expect(login.status == .off)
    #expect(!login.isChanging)
    service.status = .enabled
    login.refresh()
    #expect(login.status == .enabled)
}
