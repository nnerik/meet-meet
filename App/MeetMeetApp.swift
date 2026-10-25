import AppKit
import SwiftUI
import MeetMeetCore
import Combine
import EventKit
import Observation

@main
enum MeetMeetApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState(storage: UserDefaultsStateStore())
    private let navigation = SettingsNavigation()
    private let login = LoginLaunchSession(service: LoginLaunchService())
    private lazy var setup = OnboardingSession(state: state)
    private lazy var live = MeetingSession(reader: EventKitCalendarReader(), state: state, player: SystemSoundPlayer(), cueHandled: { [weak self] cues in
        self?.hud.showCueWiggles(for: cues.map(\.occurrence))
    })
    private var session: CalendarSession { live.calendarSession }
    private var audioCues: AudioCueSession { live.audioCues }
    private lazy var hud = CountdownHUDController(state: state, session: session)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var timer: Timer?
    private var observers: Set<AnyCancellable> = []
    private var tickCount = 0
    private var titleObservationGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Meet Meet")
        item.button?.toolTip = "Meet Meet"

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        live.start()
        hud.start()
        installObservers()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        titleObservationGeneration += 1
        observeTitle(titleObservationGeneration)
        if setup.isPresented { showSettings() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if session.isPaused {
            if let expiry = state.pauseUntil {
                addLabel("Paused until \(expiry.formatted(date: .abbreviated, time: .shortened))", to: menu)
            }
            menu.addItem(.separator())
        }
        if session.status == .ready {
            let presentation = session.presentation
            if presentation.remainingToday.isEmpty { addLabel("No remaining meetings today", to: menu) }
            for event in presentation.remainingToday {
                let ongoing = event.phase(at: session.now) == .ongoing
                let time = formattedTime(ongoing ? event.end : event.start)
                addMeeting(event, title: "\(ongoing ? "Until " : "")\(time)  \(MeetingText.displayTitle(event.title))", to: menu)
            }
            if case let .upcoming(meetings, true) = presentation.summary {
                menu.addItem(.separator())
                for event in meetings { addMeeting(event, title: "Tomorrow \(formattedTime(event.start))  \(MeetingText.displayTitle(event.title))", to: menu) }
            }
        } else {
            addLabel(session.status.message, to: menu)
        }
        let calendars = menu.addItem(withTitle: "Choose Calendars…", action: #selector(chooseCalendars), keyEquivalent: "")
        calendars.target = self
        let retry = menu.addItem(withTitle: "Refresh Calendars", action: #selector(refreshCalendars), keyEquivalent: "r")
        retry.target = self
        retry.isEnabled = session.status != .refreshing
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: session.isPaused ? "Resume" : "Pause for Today", action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        let hidden = menu.addItem(withTitle: "Manage Hidden Events…", action: #selector(manageHiddenEvents), keyEquivalent: "")
        hidden.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let quit = menu.addItem(withTitle: "Quit Meet Meet", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
    }

    private func addLabel(_ title: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = title
    }

    private func addMeeting(_ event: MeetingOccurrence, title: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let calendarTitle = session.calendars.first { $0.id == event.calendarID }?.title ?? "Calendar"
        let phase = event.phase(at: session.now) == .ongoing ? "Ongoing" : "Upcoming"
        item.setAccessibilityLabel("\(phase): \(MeetingText.displayTitle(event.title)), \(calendarTitle), starts \(event.start.formatted()), ends \(event.end.formatted())")
        item.toolTip = MeetingText.displayTitle(event.title)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        addLabel(MeetingText.displayTitle(event.title), to: submenu)
        addLabel("\(phase) · \(calendarTitle)", to: submenu)
        addLabel("Starts: \(event.start.formatted(date: .abbreviated, time: .shortened))", to: submenu)
        addLabel("Ends: \(event.end.formatted(date: .abbreviated, time: .shortened))", to: submenu)
        if let location = event.location, !location.isEmpty { addLabel("Location: " + location, to: submenu) }
        if let url = event.url { addLabel(url.absoluteString, to: submenu) }
        submenu.addItem(.separator())
        let occurrence = addMeetingAction("Hide this meeting", selector: #selector(hideOccurrence(_:)), event: event, to: submenu)
        occurrence.isEnabled = event.identityEvidence != nil
        let series = addMeetingAction("Hide this series", selector: #selector(hideSeries(_:)), event: event, to: submenu)
        series.isEnabled = event.identityEvidence?.isRecurring == true || event.identityEvidence?.isDetached == true
        submenu.addItem(.separator())
        let visibility = session.reminders.visibility(of: session.occurrences, at: Date())
        if visibility.suppressedCountdowns.contains(event.key) {
            addMeetingAction("Show countdown now", selector: #selector(restoreCountdown(_:)), event: event, to: submenu)
        } else {
            let suppress = addMeetingAction("Hide countdown until final minute", selector: #selector(suppressCountdown(_:)), event: event, to: submenu)
            let boundary = event.start > Date() ? event.start : event.end
            suppress.isEnabled = boundary.timeIntervalSinceNow > 60
        }
        item.submenu = submenu
    }

    @discardableResult
    private func addMeetingAction(_ title: String, selector: Selector, event: MeetingOccurrence, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = event.key
        return item
    }

    private func performReminderAction(_ sender: NSMenuItem, action: (MeetingOccurrence) throws -> Void) {
        guard let key = sender.representedObject as? OccurrenceKey else { return }
        let matches = session.occurrences.filter { $0.key == key }
        do {
            guard session.status == .ready, matches.count == 1 else { throw ReminderRuleError.ambiguousOccurrence }
            try action(matches[0])
            updateTitle()
        } catch {
            presentError(error, title: "Could not update reminders")
        }
    }

    @objc private func hideOccurrence(_ sender: NSMenuItem) { hide(sender, scope: .occurrence) }
    @objc private func hideSeries(_ sender: NSMenuItem) { hide(sender, scope: .series) }

    private func hide(_ sender: NSMenuItem, scope: HideScope) {
        performReminderAction(sender) { event in
            let title = session.calendars.first { $0.id == event.calendarID }?.title ?? "Calendar"
            try session.reminders.hide(event, scope: scope, calendarTitle: title, in: session.occurrences, at: Date())
        }
    }

    @objc private func suppressCountdown(_ sender: NSMenuItem) {
        performReminderAction(sender) { try session.reminders.suppressCountdown($0, at: Date()) }
    }

    @objc private func restoreCountdown(_ sender: NSMenuItem) {
        performReminderAction(sender) { try session.reminders.restoreCountdown($0.key) }
    }

    @objc private func manageHiddenEvents() {
        navigation.tab = .hiddenEvents
        showSettings()
    }

    @objc private func chooseCalendars() {
        navigation.tab = .calendars
        showSettings()
    }

    @objc private func togglePause() {
        do {
            if session.isPaused { try session.resume() }
            else { try session.pauseForToday() }
            updateTitle()
        } catch { presentError(error, title: "Could not change pause state") }
    }

    private func presentError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func updateTitle() {
        let title = live.menuBarState.text(titleLimit: state.preferences.menuTitleLimit, formatTime: formattedTime)
        let display = title.isEmpty ? "" : " " + title
        if statusItem?.button?.title != display { statusItem?.button?.title = display }
    }

    private func observeTitle(_ token: Int) {
        withObservationTracking {
            _ = live.menuBarState
            _ = state.preferences.menuTitleLimit
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.titleObservationGeneration == token else { return }
                self.observeTitle(token)
            }
        }
        updateTitle()
    }

    private func installObservers() {
        let names: [Notification.Name] = [.EKEventStoreChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged, NSApplication.didBecomeActiveNotification]
        for name in names {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.live.invalidate()
                }
                .store(in: &observers)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.live.setSleeping(false)
            }
            .store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.live.setSleeping(true)
                }
            }
            .store(in: &observers)
    }

    @objc private func refreshCalendars() { Task { await live.refresh(); updateTitle() } }

    @objc private func tick() {
        live.tick()
        updateTitle()
        tickCount += 1
        if tickCount % 30 == 0 { Task { await session.checkAccess() } }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Meet Meet Settings"
            window.identifier = NSUserInterfaceItemIdentifier("meetmeet.settings")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(state: state, session: session, hud: hud, audioCues: audioCues, setup: setup, login: login, navigation: navigation))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        observers.removeAll()
        titleObservationGeneration += 1
        hud.stop()
        live.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}

private enum SettingsTab: Hashable { case general, calendars, audio, hiddenEvents }

@MainActor @Observable
private final class SettingsNavigation { var tab = SettingsTab.general }

private struct SettingsView: View {
    let state: AppState
    let session: CalendarSession
    let hud: CountdownHUDController
    let audioCues: AudioCueSession
    let setup: OnboardingSession
    let login: LoginLaunchSession
    @Bindable var navigation: SettingsNavigation
    @State private var errorMessage: String?
    @State private var confirmUnhideAll = false

    var body: some View {
        if setup.isPresented {
            OnboardingView(setup: setup, state: state, session: session, login: login)
        } else {
            settingsBody
        }
    }

    private var settingsBody: some View {
        VStack(spacing: 0) {
            if !state.recoveryNotices.isEmpty {
                Label("Some saved records could not be read. Other settings are unchanged; newer records are preserved.", systemImage: "exclamationmark.triangle")
                    .font(.callout).padding()
            }
            if let error = session.reminders.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).padding()
            }
            if let error = session.pausePersistenceError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).padding()
            }
            if let error = hud.positionError {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).padding()
            }
            TabView(selection: $navigation.tab) {
                Tab("General", systemImage: "gearshape", value: SettingsTab.general) { general }
                Tab("Calendars", systemImage: "calendar", value: SettingsTab.calendars) { CalendarSettingsView(state: state, session: session) }
                Tab("Audio", systemImage: "speaker.wave.2", value: SettingsTab.audio) { audio }
                Tab("Hidden Events", systemImage: "eye.slash", value: SettingsTab.hiddenEvents) { hiddenEvents }
            }
        }
        .frame(width: 580, height: 460)
        .alert("Could not save settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var general: some View {
        Form {
            Section("Countdowns") {
                IntegerSettingField("Show before start", value: preference(\.hudLeadMinutes), range: 0...120, unit: "minutes")
                Text("Zero shows ongoing countdowns only.").font(.caption).foregroundStyle(.secondary)
                IntegerSettingField("Show seconds below", value: preference(\.secondsThresholdMinutes), range: 0...60, unit: "minutes")
                Text("Zero disables seconds.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                IntegerSettingField("Title length", value: preference(\.menuTitleLimit), range: 8...80, unit: "characters")
            }
            Section("Login") {
                LoginLaunchControls(login: login)
            }
            Section {
                Text("Preferences save immediately. Live countdowns and optional sounds follow your selected calendars.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Review Setup…") { setup.present() }
            }
        }
        .formStyle(.grouped)
    }

    private var audio: some View {
        Form {
            Section("Before start") {
                Toggle("Enable start cue", isOn: preference(\.startCue.isEnabled))
                Picker("Sound", selection: preference(\.startCue.soundName)) {
                    ForEach(soundNames, id: \.self) { Text($0).tag($0) }
                }
                IntegerSettingField("Before start", value: preference(\.startCue.offsetMinutes), range: 0...60, unit: "minutes")
                Button("Preview start sound") { audioCues.preview(named: state.preferences.startCue.soundName) }
            }
            Section("Before end") {
                Toggle("Enable end cue", isOn: preference(\.endCue.isEnabled))
                Picker("Sound", selection: preference(\.endCue.soundName)) {
                    ForEach(soundNames, id: \.self) { Text($0).tag($0) }
                }
                IntegerSettingField("Before end", value: preference(\.endCue.offsetMinutes), range: 0...60, unit: "minutes")
                Button("Preview end sound") { audioCues.preview(named: state.preferences.endCue.soundName) }
            }
            Section("Playback") {
                Slider(value: preference(\.audioVolume), in: 0...1) { Text("App volume") }
                Text("Zero-minute offsets mean the meeting boundary. App volume does not change system volume. Missed cues are skipped after interruptions; sounds are best-effort while the app is running.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = audioCues.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hiddenEvents: some View {
        Form {
            Section {
                Text("Hiding filters reminders, not attendance, and never changes your calendars. Unmatched rules are kept so you can remove them here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            hiddenSection("Meetings", scope: .occurrence)
            hiddenSection("Series", scope: .series)
            Section {
                Button("Unhide All", role: .destructive) { confirmUnhideAll = true }
                    .disabled(state.hiddenEvents.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Unhide all meetings and series?", isPresented: $confirmUnhideAll) {
            Button("Unhide All", role: .destructive) {
                do { try session.reminders.unhideAll() }
                catch { errorMessage = error.localizedDescription }
            }
        } message: { Text("Normal calendar filters and any temporary countdown hiding will still apply.") }
    }

    private func hiddenSection(_ title: String, scope: HideScope) -> some View {
        Section(title) {
            let rules = state.hiddenEvents.filter { $0.scope == scope }
            if rules.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(rules) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.title)
                        Text(rule.calendarTitle).font(.caption).foregroundStyle(.secondary)
                        if let date = rule.originalOccurrenceDate ?? rule.knownEnd {
                            Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Unhide") {
                        do { try session.reminders.unhide(rule.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
    }

    private var soundNames: [String] {
        let names = SystemSoundPlayer.soundNames
        return Set(names + [state.preferences.startCue.soundName, state.preferences.endCue.soundName]).sorted()
    }

    private func preference<Value>(_ key: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { state.preferences[keyPath: key] },
            set: { value in
                do { try state.updatePreferences { $0[keyPath: key] = value } }
                catch { errorMessage = error.localizedDescription }
            }
        )
    }
}

private struct IntegerSettingField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    @State private var draft: String
    @State private var validationMessage: String?
    @FocusState private var focused: Bool

    init(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, unit: String) {
        self.title = title
        self._value = value
        self.range = range
        self.unit = unit
        self._draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, text: $draft)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 60)
                    .focused($focused)
                    .onSubmit(commit)
                    .accessibilityValue("\(draft) \(unit)")
                Text(unit).foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range)
                    .labelsHidden()
                    .fixedSize()
            }
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onChange(of: value) { _, updated in draft = String(updated); validationMessage = nil }
        .onDisappear { if focused { commit() } }
    }

    private func commit() {
        guard let number = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(number) else {
            validationMessage = "Enter a whole number from \(range.lowerBound) to \(range.upperBound)."
            return
        }
        value = number
        draft = String(value)
        validationMessage = nil
    }
}
