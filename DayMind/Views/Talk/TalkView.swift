import SwiftUI
import UIKit
import DayMindCore

struct TalkView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typedText = ""
    @State private var result: AssistantResult?
    @State private var showReminderForm = false
    @State private var showMemoryForm = false
    @State private var isHandling = false
    @FocusState private var textFieldFocused: Bool

    private var voice: VoiceController { env.voice }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        modeBanner
                        transcriptCard
                        if let result {
                            responseCard(result)
                            ForEach(result.actions) { ActionCardView(record: $0) }
                            pendingControls(result)
                            suggestionControls(result)
                        }
                        historySection
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: result) { _, _ in
                    if !reduceMotion { withAnimation { proxy.scrollTo("bottom") } } else { proxy.scrollTo("bottom") }
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .navigationTitle("Talk")
            .toolbar { SettingsToolbarButton() }
            .onAppear {
                voice.onInterrupted = { text in
                    env.inbox.add(text: text, source: .voice, reason: .speechFailed, detail: "Listening was interrupted before you finished.")
                }
                if router.autoStartListening {
                    router.autoStartListening = false
                    Task { await voice.startListening() }
                }
            }
            .onChange(of: router.autoStartListening) { _, auto in
                if auto, router.selectedTab == .talk {
                    router.autoStartListening = false
                    Task { await voice.startListening() }
                }
            }
            .sheet(isPresented: $showReminderForm) {
                NavigationStack {
                    ReminderEditorView(mode: .create(prefill: result?.suggestedReminder ?? ReminderDraft(title: voice.liveTranscript)),
                                       inboxItemToResolve: result?.inboxItemID.flatMap { env.inbox.fetch(id: $0) })
                }
            }
            .sheet(isPresented: $showMemoryForm) {
                NavigationStack {
                    MemoryEditorView(mode: .create(prefill: result?.suggestedMemory ?? MemoryDraft(title: "", content: voice.liveTranscript)),
                                     inboxItemToResolve: result?.inboxItemID.flatMap { env.inbox.fetch(id: $0) })
                }
            }
        }
    }

    // MARK: Pieces

    private var modeBanner: some View {
        let availability = env.assistant.lastAvailability
        return HStack(spacing: 8) {
            Image(systemName: availability.isAvailable ? "apple.intelligence" : "gearshape.2")
                .foregroundStyle(availability.isAvailable ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(availability.isAvailable ? "Apple Intelligence — on this iPhone" : "Offline mode — built-in rules")
                    .font(.footnote.weight(.semibold))
                if !availability.isAvailable {
                    Text(availability.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !availability.isAvailable {
                Button("Retry") { env.assistant.refreshAvailability() }.font(.caption)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(voice.state.label).font(.headline)
                Spacer()
                if voice.state == .listening {
                    ListeningIndicator()
                }
            }
            if !voice.liveTranscript.isEmpty {
                Text(voice.liveTranscript)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Transcript: \(voice.liveTranscript)")
            } else if voice.state == .idle {
                Text("Try: “Remind me tomorrow at 3 PM to call Michael” or “Remember that John prefers text messages.”")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if case .failure(let message) = voice.state {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func responseCard(_ result: AssistantResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("DayMind", systemImage: "brain.head.profile").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(result.mode.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            Text(result.responseText).font(.body)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func pendingControls(_ result: AssistantResult) -> some View {
        if let pending = result.pending {
            switch pending {
            case .chooseReminder(let candidates, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Which one?").font(.subheadline.weight(.semibold))
                    ForEach(candidates) { c in
                        Button {
                            Task { await run { await env.assistant.choose(reminderID: c.id) } }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(c.title)
                                    if let d = c.dueDate { Text(SpokenFormatter.dateTimePhrase(d, now: Date(), calendar: env.settings.calendar)).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Cancel", role: .cancel) { result = env.assistant.cancelPending() }
                }
            default:
                HStack {
                    Button(role: pending.isDestructive ? .destructive : nil) {
                        Task { await run { await env.assistant.confirmPending() } }
                    } label: {
                        Label(pending.isDestructive ? "Yes, delete" : "Yes", systemImage: pending.isDestructive ? "trash" : "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(pending.isDestructive ? .red : .accentColor)
                    Button { result = env.assistant.cancelPending() } label: {
                        Label("No, cancel", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionControls(_ result: AssistantResult) -> some View {
        if result.suggestedReminder != nil || result.suggestedMemory != nil || result.inboxItemID != nil {
            HStack {
                Button { showReminderForm = true } label: { Label("Make a reminder", systemImage: "bell").frame(maxWidth: .infinity) }
                Button { showMemoryForm = true } label: { Label("Save as note", systemImage: "brain").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.bordered)
        }
    }

    private var historySection: some View {
        let turns = env.conversation.recent(limit: 12)
        return Group {
            if turns.count > 2 {
                DisclosureGroup("Earlier") {
                    ForEach(turns) { turn in
                        HStack(alignment: .top) {
                            Text(turn.role == .user ? "You" : "DayMind").font(.caption.weight(.semibold)).frame(width: 60, alignment: .leading)
                            Text(turn.text).font(.caption)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                    }
                }
                .font(.footnote)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                if voice.state == .listening {
                    Button { voice.cancelListening() } label: { Label("Cancel", systemImage: "xmark").labelStyle(.iconOnly).font(.title3).frame(width: 52, height: 52) }
                        .buttonStyle(.bordered).clipShape(Circle())
                        .accessibilityLabel("Cancel listening")
                } else if voice.state == .speaking {
                    Button { voice.stopSpeaking() } label: { Label("Stop speaking", systemImage: "speaker.slash").labelStyle(.iconOnly).font(.title3).frame(width: 52, height: 52) }
                        .buttonStyle(.bordered).clipShape(Circle())
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
                MicButton(state: voice.state) {
                    Task { await micTapped() }
                }
                Button { textFieldFocused = true } label: { Label("Type", systemImage: "keyboard").labelStyle(.iconOnly).font(.title3).frame(width: 52, height: 52) }
                    .buttonStyle(.bordered).clipShape(Circle())
                    .accessibilityLabel("Type instead")
            }
            HStack {
                TextField("Type a request…", text: $typedText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($textFieldFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendTyped() } }
                Button { Task { await sendTyped() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty || isHandling)
                    .accessibilityLabel("Send")
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: Actions


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
            result = nil
            await voice.startListening()
        }
    }

    private func sendTyped() async {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedText = ""
        textFieldFocused = false
        await process(text, source: .text)
    }

    private func process(_ text: String, source: CaptureSource) async {
        guard !text.isEmpty else {
            voice.setFailure("I didn't hear anything. Try again.")
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
        result = r
        if r.actions.contains(where: { $0.changedData }) { voice.setSaving() }
        if r.actions.contains(where: { $0.isProblem }) { voice.setFailure("Not saved — see below") } else { voice.setSuccess() }
        await voice.speak(r.responseText)
        if !voice.state.isBusy { voice.setIdle() }
    }
}

struct ListeningIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(Color.accentColor)
                    .frame(width: 4, height: phase ? CGFloat(10 + (i % 2) * 10) : CGFloat(6 + ((i + 1) % 2) * 10))
            }
        }
        .frame(height: 22)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { phase.toggle() }
        }
        .accessibilityHidden(true)
    }
}
