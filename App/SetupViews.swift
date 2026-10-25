import AppKit
import MeetMeetCore
import SwiftUI

struct OnboardingView: View {
    let setup: OnboardingSession
    let state: AppState
    let session: CalendarSession
    let login: LoginLaunchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text("Step \(setup.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                switch setup.step {
                case .welcome:
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Upcoming and ongoing countdowns, without calendar changes.", systemImage: "calendar")
                        Text("Meet Meet lives in the calendar menu in your menu bar, not the Dock. Use that menu for meeting actions, Pause for Today, Settings and Quit.")
                        Text("Choose which calendars to monitor. Sounds and launch at login are optional and off by default for new settings.")
                        Text("No accounts, telemetry or backend. Your selections and reminder rules stay on this Mac.")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .calendars:
                    CalendarSettingsView(state: state, session: session)
                case .login:
                    Form {
                        Section("Optional launch at login") { LoginLaunchControls(login: login) }
                        Section("Ready") {
                            Text(state.selectedCalendarIDs.isEmpty
                                 ? "No calendars selected. You can finish now and choose them later from the calendar menu."
                                 : "Your saved calendar selections are kept. Countdown presentation resumes when fresh calendar data is available.")
                            Text("Closing the last window keeps Meet Meet running. Quit from the calendar menu to stop it; an enabled login item starts it at your next login, not immediately after Quit.")
                        }
                    }.formStyle(.grouped)
                }
            }
            if let error = setup.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
            }
            HStack {
                if setup.step != .welcome { Button("Back") { setup.back() } }
                Spacer()
                if setup.step == .login {
                    Button("Finish Setup") { setup.finish() }
                        .disabled(login.isChanging)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { setup.next() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 580, height: 460)
    }

    private var title: String {
        switch setup.step {
        case .welcome: "Welcome to Meet Meet"
        case .calendars: "Choose your calendars"
        case .login: "Make it yours"
        }
    }
}

struct LoginLaunchControls: View {
    let login: LoginLaunchSession

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { login.status.isRequested }, set: { enabled in
            Task { await login.setEnabled(enabled) }
        }))
        .disabled(login.isChanging || login.status == .unavailable || login.status == .unknown)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
        LabeledContent("Status", value: login.status.description)
        if login.isChanging { ProgressView().controlSize(.small) }
        if login.status == .requiresApproval {
            Text("Requested, but not enabled until macOS approves it. Allow Meet Meet under Login Items.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Button("Open Login Items Settings") { LoginLaunchService.openSettings() }
        Text("Keep the app in a stable location, such as Applications, before enabling. Moving or deleting this app build can invalidate the login item.")
            .font(.caption).foregroundStyle(.secondary)
        if let error = login.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout)
        }
    }
}

struct CalendarSettingsView: View {
    let state: AppState
    let session: CalendarSession
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Calendar access") {
                Text("Meet Meet only reads events. macOS requires full calendar access to read your selected calendars; the app never creates, edits or deletes events.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Status", value: session.status.message)
                if session.access == .notRequested || session.access == .unreadable {
                    Button("Allow Calendar Access") { Task { await session.requestAccess() } }
                        .disabled(session.status == .refreshing)
                } else if session.access == .denied || session.access == .restricted {
                    Button("Open Calendar Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                if session.status == .refreshing { ProgressView().controlSize(.small) }
                Button("Refresh / Retry") { Task { await session.refresh() } }
                    .disabled(session.status == .refreshing)
            }
            if !session.calendars.isEmpty {
                Section("Calendars to monitor") {
                    ForEach(session.calendars) { calendar in
                        Toggle(isOn: calendarSelection(calendar.id)) {
                            Text(calendar.title)
                            Text(calendar.sourceTitle).font(.caption).foregroundStyle(.secondary)
                        }.toggleStyle(.checkbox)
                    }
                }
            }
            Section {
                Text("Choose none to stay idle. New calendars stay unselected. Choices are preserved if a calendar or permission temporarily disappears.")
                    .font(.caption).foregroundStyle(.secondary)
                if session.status == .ready {
                    Text("\(session.presentation.remainingToday.count) eligible remaining meetings today.")
                        .font(.callout)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func calendarSelection(_ id: String) -> Binding<Bool> {
        Binding(get: { state.selectedCalendarIDs.contains(id) }, set: { selected in
            var ids = state.selectedCalendarIDs
            if selected { ids.insert(id) } else { ids.remove(id) }
            do { try state.setSelectedCalendarIDs(ids); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        })
    }
}
