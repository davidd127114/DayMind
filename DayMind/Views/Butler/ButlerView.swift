import SwiftUI
import SwiftData
import UIKit
import DayMindCore

/// The home screen: a butler you talk to. Speak or type → clarify only if needed → saved → confirmed.
struct ButlerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    @Query(filter: #Predicate<Reminder> { $0.statusRaw == "pending" }, sort: \Reminder.dueDate, order: .forward)
    private var pendingReminders: [Reminder]
    @Query(filter: #Predicate<InboxItem> { !$0.isResolved }, sort: \InboxItem.capturedAt, order: .reverse)
    private var unresolved: [InboxItem]

    @State private var typedText = ""
    @State private var results: [AssistantResult] = []
    @State private var showEarlier = false
    @State private var editingReminder: Reminder?
    @State private var editingMemory: Memory?
    @State private var isHandling = false
    @State private var now = Date()
    @FocusState private var inputFocused: Bool

    private var voice: VoiceController { env.voice }
    private var latest: AssistantResult? { results.last }
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ButlerTheme.ivory.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        butlerButton
                        statusLine
                        if !voice.liveTranscript.isEmpty, voice.state == .listening || voice.state == .processing {
                            transcriptCard
                        }
                        if let latest {
                            responseBubble(latest)
                            ForEach(latest.actions) { record in
                                ConfirmationCardView(record: record,
                                                     onUndo: { rec in Task { await run { await env.assistant.undo(rec) } } },
                                                     onDone: { id in Task { await run { await env.assistant.complete(reminderID: id) } } },
                                                     onEditReminder: { id in editingReminder = env.reminders.fetch(id: id) },
                                                     onEditMemory: { id in editingMemory = env.memories.fetch(id: id) },
                                                     onChoose: { id in Task { await run { await env.assistant.choose(reminderID: id) } } },
                                                     onConfirm: { Task { await run { await env.assistant.confirmPending() } } },
                                                     onCancel: { results.append(env.assistant.cancelPending()) })
                            }
                            suggestionButtons(latest)
                        }
                        if !unresolved.isEmpty { needsAttentionBanner }
                        nextUpSection
                        earlierSection
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: results.count) { _, _ in
                    if reduceMotion { proxy.scrollTo("bottom") } else { withAnimation { proxy.scrollTo("bottom") } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(clock) { now = $0 }
        .onAppear(perform: onAppear)
        .onChange(of: router.autoStartListening) { _, auto in
            if auto { router.autoStartListening = false; Task { await voice.startListening() } }
        }
        .onChange(of: router.reminderToOpen) { _, id in
            guard let id, let r = env.reminders.fetch(id: id) else { return }
            editingReminder = r
            router.reminderToOpen = nil
        }
        .sheet(item: $editingReminder, onDismiss: pruneResults) { r in NavigationStack { ReminderEditorView(mode: .edit(r)) } }
        .sheet(item: $editingMemory, onDismiss: pruneResults) { m in NavigationStack { MemoryEditorView(mode: .edit(m)) } }
        .onChange(of: env.store.changeCount) { _, _ in pruneResults() }
    }

    /// Keeps the cards truthful: a card about a reminder or note that no longer exists becomes a
    /// "Removed" card, and summaries are refreshed so edits made in a sheet show immediately.
    private func pruneResults() {
        now = Date()
        results = results.map { result in
            var r = result
            r.actions = result.actions.map { record in
                if let id = record.reminderID, env.reminders.fetch(id: id) == nil {
                    switch record.kind {
                    case .reminderCreated(let s), .reminderUpdated(let s, _), .reminderSnoozed(let s, _), .reminderFollowUpSet(let s, _), .reminderCompleted(let s, _):
                        return ActionRecord(.reminderDeleted(title: s.title))
                    default: return record
                    }
                }
                if let id = record.memoryID, env.memories.fetch(id: id) == nil {
                    switch record.kind {
                    case .memorySaved(let m), .memoryUpdated(let m, _): return ActionRecord(.memoryDeleted(title: m.title))
                    default: return record
                    }
                }
                // Refresh the summary so an edited title/time shows on the card.
                if let id = record.reminderID, let live = env.reminders.fetch(id: id) {
                    let fresh = env.reminders.summary(live)
                    switch record.kind {
                    case .reminderCreated: return replacing(record, with: .reminderCreated(fresh))
                    case .reminderUpdated(_, let change): return replacing(record, with: .reminderUpdated(fresh, change: change))
                    case .reminderSnoozed(_, let until): return replacing(record, with: .reminderSnoozed(fresh, until: until))
                    case .reminderFollowUpSet(_, let at): return replacing(record, with: .reminderFollowUpSet(fresh, at: at))
                    case .reminderCompleted(_, let next): return replacing(record, with: .reminderCompleted(fresh, nextOccurrence: next))
                    default: return record
                    }
                }
                return record
            }
            return r
        }
    }

    private func replacing(_ record: ActionRecord, with kind: ActionRecord.Kind) -> ActionRecord {
        ActionRecord(id: record.id, kind: kind, timestamp: record.timestamp)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if typeSize.isAccessibilitySize {
            // Large text: stack so nothing wraps letter by letter.
            VStack(alignment: .leading, spacing: 10) {
                Text(greeting).font(.title2.weight(.semibold)).foregroundStyle(ButlerTheme.ink)
                Text(env.briefing.headline()).font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
                HStack { bookButton; Spacer(); settingsButton }
            }
            .padding(.top, 4)
        } else {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting).font(.title2.weight(.semibold)).foregroundStyle(ButlerTheme.ink)
                    Text(env.briefing.headline()).font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
                }
                Spacer()
                bookButton
                settingsButton
            }
            .padding(.top, 4)
        }
    }

    private var bookButton: some View {
        Button { router.openBook() } label: {
            Label("My Book", systemImage: "book.closed")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(ButlerTheme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(ButlerTheme.goldSoft))
        }
        .foregroundStyle(ButlerTheme.ink)
        .accessibilityIdentifier("openMyBook")
    }

    private var settingsButton: some View {
        Button { router.showSettings = true } label: {
            Image(systemName: "gearshape").font(.body).padding(8)
        }
        .foregroundStyle(ButlerTheme.inkSecondary)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("openSettings")
    }

    private var greeting: String {
        let hour = env.settings.calendar.component(.hour, from: now)
        switch hour {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default: return "Hello."
        }
    }

    // MARK: Butler (the mic button)

    private var butlerButton: some View {
        Button { Task { await micTapped() } } label: {
            ButlerFigureView(state: voice.state, size: typeSize.isAccessibilitySize ? 200 : 250)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isHandling && voice.state != .speaking)
        .accessibilityIdentifier("butlerMic")
        .accessibilityLabel("Talk to your butler")
        .accessibilityValue(voice.state.label)
        .accessibilityHint(voice.state == .listening ? "Double tap to stop and save" : "Double tap, then say what to remember or when to remind you")
        .accessibilityAddTraits(.startsMediaSession)
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if voice.state == .listening { WaveformView(animating: !reduceMotion && !LaunchOptions.isUITesting).frame(height: 18).accessibilityHidden(true) }
            Text(statusText)
                .font(.body)
                .foregroundStyle(statusIsProblem ? ButlerTheme.failure : ButlerTheme.inkSecondary)
                .multilineTextAlignment(.center)
            if voice.state == .listening {
                Button("Cancel") { voice.cancelListening() }.font(.subheadline).foregroundStyle(ButlerTheme.ink)
            } else if voice.state == .speaking {
                Button("Stop") { voice.stopSpeaking() }.font(.subheadline).foregroundStyle(ButlerTheme.ink)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch voice.state {
        case .idle: return latest == nil ? "Tap the butler and tell me what to remember." : "Anything else?"
        case .requestingPermission: return "Asking for microphone access…"
        case .listening: return "Listening… tap again when you're done."
        case .processing: return "One moment…"
        case .saving: return "Saving…"
        case .speaking: return "Speaking…"
        case .success: return "Done."
        case .failure(let message): return message
        }
    }

    private var statusIsProblem: Bool { if case .failure = voice.state { return true }; return false }

    private var transcriptCard: some View {
        Text(voice.liveTranscript)
            .font(.title3)
            .foregroundStyle(ButlerTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .butlerCard()
            .accessibilityLabel("Heard so far: \(voice.liveTranscript)")
    }

    // MARK: Response

    private func responseBubble(_ result: AssistantResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening").font(.caption).foregroundStyle(ButlerTheme.gold).padding(.top, 4).accessibilityHidden(true)
            Text(result.responseText).font(.body).foregroundStyle(ButlerTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func suggestionButtons(_ result: AssistantResult) -> some View {
        if result.suggestedReminder != nil || result.suggestedMemory != nil || result.inboxItemID != nil {
            HStack {
                Button { editingReminder = nil; draftReminderSheet = result } label: { Label("Make a reminder", systemImage: "bell").frame(maxWidth: .infinity) }
                Button { draftMemorySheet = result } label: { Label("Save as note", systemImage: "book.closed").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
            .tint(ButlerTheme.ink)
            .sheet(item: $draftReminderSheet) { r in
                NavigationStack {
                    ReminderEditorView(mode: .create(prefill: r.suggestedReminder ?? ReminderDraft(title: voice.liveTranscript)),
                                       inboxItemToResolve: r.inboxItemID.flatMap { env.inbox.fetch(id: $0) })
                }
            }
            .sheet(item: $draftMemorySheet) { r in
                NavigationStack {
                    MemoryEditorView(mode: .create(prefill: r.suggestedMemory ?? MemoryDraft(title: "", content: voice.liveTranscript)),
                                     inboxItemToResolve: r.inboxItemID.flatMap { env.inbox.fetch(id: $0) })
                }
            }
        }
    }
    @State private var draftReminderSheet: AssistantResult?
    @State private var draftMemorySheet: AssistantResult?

    // MARK: Needs attention + next up

    private var needsAttentionBanner: some View {
        Button { router.openBook(.needsAttention) } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.full").foregroundStyle(ButlerTheme.attention)
                Text(unresolved.count == 1 ? "One request needs your attention" : "\(unresolved.count) requests need your attention")
                    .font(.subheadline.weight(.medium)).foregroundStyle(ButlerTheme.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(ButlerTheme.inkSecondary)
            }
            .butlerCard(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("needsAttention")
    }

    private var nextUp: [Reminder] {
        let overdue = pendingReminders.filter { ($0.dueDate ?? .distantFuture) < now }
        let upcoming = pendingReminders.filter { ($0.dueDate ?? .distantFuture) >= now }
        return Array((overdue + upcoming).prefix(3))
    }

    @ViewBuilder
    private var nextUpSection: some View {
        if latest == nil || voice.state == .idle {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(nextUp.isEmpty ? "Nothing scheduled" : "Next up").font(.headline).foregroundStyle(ButlerTheme.ink)
                    Spacer()
                    if !pendingReminders.isEmpty {
                        Button("See all") { router.openBook(.upcoming) }.font(.subheadline).foregroundStyle(ButlerTheme.ink)
                    }
                }
                if nextUp.isEmpty {
                    Text("Say something like “Remind me tomorrow at 3 PM to call Michael” or “Remember that John prefers text messages.”")
                        .font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
                }
                ForEach(nextUp) { r in
                    ReminderRow(reminder: r, now: now,
                                onComplete: { Task { _ = try? await env.reminders.complete(r) } },
                                onSnooze: { interval in Task { _ = try? await env.reminders.snooze(r, by: interval) } })
                        .contentShape(Rectangle())
                        .onTapGesture { editingReminder = r }
                }
            }
            .butlerCard()
        }
    }

    // MARK: Earlier

    @ViewBuilder
    private var earlierSection: some View {
        let turns = env.conversation.recent(limit: 20)
        if turns.count > 2 {
            DisclosureGroup(isExpanded: $showEarlier) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(turns.dropLast(min(turns.count, results.isEmpty ? 0 : 2))) { turn in
                        HStack(alignment: .top, spacing: 8) {
                            Text(turn.role == .user ? "You" : "Butler").font(.caption.weight(.semibold)).frame(width: 46, alignment: .leading)
                            Text(turn.text).font(.caption)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(ButlerTheme.inkSecondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Earlier").font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
            }
            .tint(ButlerTheme.inkSecondary)
            .padding(.horizontal, 4)
        }
    }

    // MARK: Input bar

    @State private var showPhotoSheet = false

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button { showPhotoSheet = true } label: {
                Image(systemName: "paperclip").font(.title3).padding(8)
            }
            .foregroundStyle(ButlerTheme.inkSecondary)
            .accessibilityLabel("Attach a photo or screenshot")
            .accessibilityIdentifier("attachPhoto")
            .sheet(isPresented: $showPhotoSheet) {
                PhotoCaptureSheet { result in
                    results.append(result)
                    if result.actions.contains(where: { $0.changedData }) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                    Task { await voice.speak(result.responseText) }
                }
            }
            TextField("Type a request…", text: $typedText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ButlerTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(ButlerTheme.goldSoft))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { Task { await sendTyped() } }
                .accessibilityIdentifier("butlerInput")
            Button { Task { await sendTyped() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .foregroundStyle(typedText.trimmingCharacters(in: .whitespaces).isEmpty ? ButlerTheme.inkSecondary : ButlerTheme.gold)
            .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty || isHandling)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("butlerSend")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(ButlerTheme.ivory.opacity(0.96))
    }

    // MARK: Behaviour

    private func onAppear() {
        now = Date()
        voice.onInterrupted = { text in
            env.inbox.add(text: text, source: .voice, reason: .speechFailed, detail: "Listening was interrupted before you finished.")
        }
        if router.autoStartListening {
            router.autoStartListening = false
            Task { await voice.startListening() }
        }
        if let demo = LaunchOptions.demoRequest, results.isEmpty {
            Task { await process(demo, source: .text) }
        }
    }

    private func micTapped() async {
        switch voice.state {
        case .listening:
            let text = await voice.stopListening()
            await process(text, source: .voice)
        case .speaking:
            voice.stopSpeaking()
        case .processing, .saving, .requestingPermission:
            break
        default:
            await voice.startListening()
        }
    }

    private func sendTyped() async {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedText = ""
        inputFocused = false
        await process(text, source: .text)
    }

    private func process(_ text: String, source: CaptureSource) async {
        guard !text.isEmpty else {
            voice.setFailure("I didn't catch that. Tap the butler and try again.")
            return
        }
        await run {
            voice.setProcessing()
            return await env.assistant.handle(text, source: source)
        }
    }

    private func run(_ operation: () async -> AssistantResult) async {
        isHandling = true
        defer { isHandling = false }
        let r = await operation()
        results.append(r)
        if results.count > 6 { results.removeFirst(results.count - 6) }
        if r.actions.contains(where: { $0.isProblem }) {
            voice.setFailure("Not saved — see below.")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        } else if r.actions.contains(where: { $0.changedData }) {
            voice.setSuccess()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            voice.setSuccess()
        }
        await voice.speak(r.responseText)
        if !voice.state.isBusy { voice.setIdle() }
    }
}
