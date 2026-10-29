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
    private lazy var live: MeetingSession = MeetingSession(reader: EventKitCalendarReader(), state: state, player: SystemSoundPlayer(), cueHandled: { [weak self] cues in
        self?.hud.showCueWiggles(for: cues.map(\.occurrence))
    })
    private var session: CalendarSession { live.calendarSession }
    private var audioCues: AudioCueSession { live.audioCues }
    private lazy var hud: CountdownHUDController = CountdownHUDController(state: state, session: session, showMeetingInfo: { [weak self] key in
        self?.live.showMeetingInfo(for: key)
    })
    private lazy var splash = SplashHUDController(session: live.splashCues)
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
        splash.start()
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
            let presentation = session.meetingMenu
            if presentation.remainingToday.isEmpty { addLabel("No remaining meetings today", to: menu) }
            for entry in presentation.remainingToday {
                addMeeting(entry, to: menu)
            }
            if !presentation.tomorrow.isEmpty {
                menu.addItem(.separator())
                for entry in presentation.tomorrow { addMeeting(entry, isTomorrow: true, to: menu) }
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

    private func addMeeting(_ entry: MeetingMenuEntry, isTomorrow: Bool = false, to menu: NSMenu) {
        let item = MeetingMenuItem(entry: entry, isTomorrow: isTomorrow,
                                   shortenGoogleRoomNames: state.preferences.shortenGoogleRoomNames,
                                   formatTime: formattedTime) { [weak self] action, key in
            self?.performReminderAction(action, for: key)
        }
        menu.addItem(item)
    }

    private func performReminderAction(_ action: MeetingReminderAction, for key: OccurrenceKey) {
        do {
            try live.performReminderAction(action, for: key)
            updateTitle()
        } catch {
            presentError(error, title: "Could not update reminders")
        }
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
            window.contentView = NSHostingView(rootView: SettingsView(state: state, session: session, hud: hud, splashCues: live.splashCues, audioCues: audioCues, setup: setup, login: login, navigation: navigation))
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
        splash.stop()
        live.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}

private enum SettingsTab: Hashable { case general, calendars, cues, hiddenEvents }

@MainActor @Observable
private final class SettingsNavigation { var tab = SettingsTab.general }

private struct SettingsView: View {
    let state: AppState
    let session: CalendarSession
    let hud: CountdownHUDController
    let splashCues: SplashCueSession
    let audioCues: AudioCueSession
    let setup: OnboardingSession
    let login: LoginLaunchSession
    @Bindable var navigation: SettingsNavigation
    @State private var errorMessage: String?
    @State private var confirmUnhideAll = false
    @State private var previewEnd: Bool?

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
            if let error = splashCues.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).padding()
            }
            TabView(selection: $navigation.tab) {
                Tab("General", systemImage: "gearshape", value: SettingsTab.general) { general }
                Tab("Calendars", systemImage: "calendar", value: SettingsTab.calendars) { CalendarSettingsView(state: state, session: session) }
                Tab("Cues", systemImage: "bell.badge", value: SettingsTab.cues) { cues }
                Tab("Hidden Events", systemImage: "eye.slash", value: SettingsTab.hiddenEvents) { hiddenEvents }
            }
        }
        .frame(width: 580, height: 460)
        .sheet(isPresented: Binding(get: { previewEnd != nil }, set: { if !$0 { previewEnd = nil } })) {
            visualPreview(isEnd: previewEnd ?? false)
        }
        .alert("Could not update settings", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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
            Section("Meeting locations") {
                Toggle("Shorten meeting room names", isOn: preference(\.shortenGoogleRoomNames))
                Text("Supports Google Workspace structured room names only (building-floor-room, with an optional section, capacity and features). Other location formats are left unchanged. Applies to meeting details and start visual cues; calendar events are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private var cues: some View {
        Form {
            cueSection(isEnd: false)
            cueSection(isEnd: true)
            Section("Playback") {
                Slider(value: preference(\.audioVolume), in: 0...1) { Text("App volume") }
                Text("Zero-minute offsets mean the meeting boundary. App volume does not change system volume. Missed cues are skipped after interruptions; sounds are best-effort while the app is running.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Start visual cues open meeting info, which stays open through the start until dismissed or the meeting ends. Click any HUD meeting to open its info without consuming the scheduled cue. End visual cues close at meeting end. Close with ×, or click the artwork then press Escape. Cues do not interrupt typing. Imported files are copied into Meet Meet; the originals can be moved or removed.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = audioCues.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func cueSection(isEnd: Bool) -> some View {
        let audioKey: WritableKeyPath<AppPreferences, AudioCuePreference> = isEnd ? \.endCue : \.startCue
        let imageKey: WritableKeyPath<AppPreferences, String?> = isEnd ? \.endSplashImage : \.startSplashImage
        return Section(isEnd ? "Before end" : "Before start") {
            Toggle("Audio cue", isOn: preference(audioKey.appending(path: \.isEnabled)))
            Picker("Sound", selection: preference(audioKey.appending(path: \.soundName))) {
                ForEach(SystemSoundPlayer.soundNames(isEnd: isEnd, selectedNames: [state.preferences.startCue.soundName, state.preferences.endCue.soundName]), id: \.self) {
                    Text(CueMedia.label(for: $0)).tag($0)
                }
            }
            IntegerSettingField("Audio before \(isEnd ? "end" : "start")", value: preference(audioKey.appending(path: \.offsetMinutes)), range: 0...60, unit: "minutes")
            HStack {
                Button("Choose audio file…") { importMedia(audio: true, isEnd: isEnd) }
                Button("Preview sound") { audioCues.preview(named: state.preferences[keyPath: audioKey].soundName) }
            }
            Divider()
            Toggle("Visual cue", isOn: preference(isEnd ? \.endSplashCueEnabled : \.splashCueEnabled))
            IntegerSettingField("Visual before \(isEnd ? "end" : "start")", value: preference(isEnd ? \.endSplashLeadMinutes : \.splashLeadMinutes), range: 1...60, unit: "minutes")
            LabeledContent("Image", value: state.preferences[keyPath: imageKey].map { CueMedia.label(for: $0) } ?? "Default")
            HStack {
                Button("Choose image file…") { importMedia(audio: false, isEnd: isEnd) }
                if state.preferences[keyPath: imageKey] != nil {
                    Button("Use default image") { preference(imageKey).wrappedValue = nil }
                }
                Button("Preview visual") { previewEnd = isEnd }
            }
        }
    }

    private func importMedia(audio: Bool, isEnd: Bool) {
        do {
            guard let name = try CueMedia.choose(audio: audio) else { return }
            try state.updatePreferences {
                if audio {
                    if isEnd { $0.endCue.soundName = name } else { $0.startCue.soundName = name }
                } else {
                    if isEnd { $0.endSplashImage = name } else { $0.startSplashImage = name }
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func visualPreview(isEnd: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = CueMedia.image(named: isEnd ? state.preferences.endSplashImage : state.preferences.startSplashImage, isEnd: isEnd) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 300)
            } else {
                Label("Cue image unavailable. Choose another image.", systemImage: "exclamationmark.triangle")
            }
            Text("Meeting title").font(.title2.bold())
            if !isEnd {
                Text("Meeting location (when available)")
                Button("Join", systemImage: "video.fill") {}.disabled(true)
                Text("Opens the meeting link in its default app when available.").font(.caption)
            }
            Button("Done") { previewEnd = nil }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 440)
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
