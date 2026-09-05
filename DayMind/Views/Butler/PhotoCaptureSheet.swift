import SwiftUI
import PhotosUI
import UIKit
import DayMindCore

/// Attach a photo or screenshot, read its text on device, and confirm before anything is saved.
struct PhotoCaptureSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Called with the result so the Butler screen can show a confirmation card.
    var onResult: (AssistantResult) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var extracted: ExtractedPhotoText?
    @State private var extracting = false
    @State private var error: String?
    @State private var showCamera = false

    // Review fields
    @State private var title = ""
    @State private var chosenDate: Date = Date().addingTimeInterval(86_400)
    @State private var hasDate = false
    @State private var selectedDetected: ExtractedPhotoText.DetectedDate?
    @State private var keepPhoto = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack {
                ButlerTheme.ivory.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        if image == nil { pickers } else { review }
                        if let error { Text(error).font(.footnote).foregroundStyle(ButlerTheme.failure) }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("From a photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: pickerItem) { _, item in Task { await load(item) } }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { picked in
                    showCamera = false
                    if let picked { Task { await analyze(picked) } }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Pick

    private var pickers: some View {
        VStack(spacing: 14) {
            Text("Appointment cards, screenshots and written notices work best. Text is read on this iPhone; the photo is not uploaded anywhere.")
                .font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose a photo or screenshot", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(ButlerTheme.gold)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(ButlerTheme.ink)
            }
            if extracting { ProgressView("Reading the text…") }
        }
        .butlerCard()
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                await analyze(img)
            } else {
                error = "That item could not be opened as an image."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func analyze(_ img: UIImage) async {
        image = img
        extracting = true
        error = nil
        defer { extracting = false }
        do {
            let result = try await PhotoTextExtractor.extract(from: img, calendar: env.settings.calendar, defaults: env.settings.timeDefaults)
            extracted = result
            if let first = result.detectedDates.first {
                selectedDetected = first
                chosenDate = first.date
                hasDate = true
            }
            title = PhotoDateFinder.suggestedTitle(from: result.lines, excluding: result.detectedDates.map(\.sourceText))
        } catch {
            extracted = ExtractedPhotoText(lines: [], detectedDates: [])
            self.error = error.localizedDescription + " You can still add the details by hand below."
            title = ""
        }
    }

    // MARK: Review

    @ViewBuilder
    private var review: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("The photo you attached")
        }
        if extracting {
            ProgressView("Reading the text…").butlerCard()
        } else if let extracted {
            VStack(alignment: .leading, spacing: 10) {
                Text(extracted.detectedDates.isEmpty ? "I couldn't find a date in this picture." : (extracted.detectedDates.count == 1 ? "I found this date:" : "I found several dates. Which one?"))
                    .font(.headline).foregroundStyle(ButlerTheme.ink)
                ForEach(extracted.detectedDates) { d in
                    Button {
                        selectedDetected = d; chosenDate = d.date; hasDate = true
                    } label: {
                        HStack {
                            Image(systemName: selectedDetected == d ? "checkmark.circle.fill" : "circle").foregroundStyle(ButlerTheme.gold)
                            VStack(alignment: .leading) {
                                Text(SpokenFormatter.dateTimePhrase(d.date, now: Date(), calendar: env.settings.calendar, includeTime: d.hasTime)).foregroundStyle(ButlerTheme.ink)
                                Text("from “\(d.sourceText)”").font(.caption).foregroundStyle(ButlerTheme.inkSecondary)
                                if !d.hasTime { Text("No time on the card — using your morning default").font(.caption2).foregroundStyle(ButlerTheme.attention) }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                Toggle("Set a date and time", isOn: $hasDate)
                if hasDate {
                    DatePicker("When", selection: $chosenDate, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, env.settings.timeZone)
                }
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                Toggle("Keep the photo with this item", isOn: $keepPhoto)
                Text(keepPhoto ? "The photo is stored inside DayMind on this iPhone only." : "Only the text is kept; the photo is not stored.")
                    .font(.caption).foregroundStyle(ButlerTheme.inkSecondary)
            }
            .butlerCard()

            VStack(spacing: 10) {
                Button { Task { await saveReminder() } } label: {
                    Label(hasDate ? "Remind me about this" : "Remind me (no time yet)", systemImage: "bell.badge").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(ButlerTheme.gold)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                Button { Task { await saveMemory() } } label: {
                    Label("Remember this information", systemImage: "book.closed").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(ButlerTheme.ink)
                .disabled(extracted.isEmpty || saving)
            }

            if !extracted.lines.isEmpty {
                DisclosureGroup("Text I read (\(extracted.lines.count) lines)") {
                    Text(extracted.fullText).font(.footnote.monospaced()).foregroundStyle(ButlerTheme.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                        .textSelection(.enabled)
                }
                .foregroundStyle(ButlerTheme.inkSecondary)
                .butlerCard()
            }
        }
    }

    // MARK: Save (confirmed by the user's tap)

    private func notesWithPhoto(_ base: String) -> String {
        guard keepPhoto, let image, let name = try? PhotoStore.save(image) else { return base }
        return base.isEmpty ? PhotoStore.noteReference(name) : base + "\n" + PhotoStore.noteReference(name)
    }

    private func saveReminder() async {
        saving = true
        defer { saving = false }
        env.actions.log.reset()
        env.actions.currentTranscript = nil
        let notes = notesWithPhoto(extracted?.lines.prefix(6).joined(separator: "\n") ?? "")
        let draft = ReminderDraft(title: title.trimmingCharacters(in: .whitespaces), notes: notes, dueDate: hasDate ? chosenDate : nil, hasExplicitTime: hasDate)
        _ = await env.actions.createReminder(draft: draft, allowDuplicate: true)
        finish()
    }

    private func saveMemory() async {
        saving = true
        defer { saving = false }
        env.actions.log.reset()
        env.actions.currentTranscript = nil
        let content = notesWithPhoto(extracted?.fullText ?? "")
        let draft = MemoryDraft(title: title.isEmpty ? RuleBasedInterpreter.summaryTitle(content) : title, content: content, category: .fact)
        _ = env.actions.saveMemory(draft: draft)
        finish()
    }

    private func finish() {
        let result = env.assistant.resultFromCurrentLog()
        onResult(result)
        dismiss()
    }
}

/// Minimal camera wrapper (UIKit) for taking a photo of a card or notice.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPick(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onPick(nil) }
    }
}
