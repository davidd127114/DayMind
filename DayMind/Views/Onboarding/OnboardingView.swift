import SwiftUI
import UserNotifications

/// First-launch sheet: what the butler does, notification permission, and a real test notification.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var notificationsAllowed: Bool? = nil
    @State private var testSent = false
    @State private var testError: String?

    var body: some View {
        ZStack {
            ButlerTheme.ivory.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    ButlerFigureView(state: .idle, size: 180).padding(.top, 12)
                    Text("At your service.").font(.largeTitle.weight(.semibold)).foregroundStyle(ButlerTheme.ink)
                    Text("Tap the butler and say what to remember or when to remind you. Everything stays on this iPhone.")
                        .font(.body).foregroundStyle(ButlerTheme.inkSecondary).multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 14) {
                        Label("“Remind me tomorrow at 3 PM to call Michael.”", systemImage: "bell.badge")
                        Label("“Remember that John prefers text messages.”", systemImage: "book.closed")
                        Label("“What did I tell you about John?”", systemImage: "magnifyingglass")
                    }
                    .font(.subheadline).foregroundStyle(ButlerTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .butlerCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Notifications").font(.headline).foregroundStyle(ButlerTheme.ink)
                        Text("Reminders arrive as notifications, even when the app is closed. iOS decides delivery: Focus modes and settings can silence them, so please run the test.")
                            .font(.subheadline).foregroundStyle(ButlerTheme.inkSecondary)
                        if notificationsAllowed != true {
                            Button {
                                Task { notificationsAllowed = await env.requestNotificationPermission() }
                            } label: { Label("Allow notifications", systemImage: "bell").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).tint(ButlerTheme.gold)
                            if notificationsAllowed == false {
                                Text("Notifications are off. Reminders will still be saved; enable them later in iOS Settings → DayMind.")
                                    .font(.footnote).foregroundStyle(ButlerTheme.attention)
                            }
                        } else {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(ButlerTheme.success)
                            Button {
                                Task {
                                    testError = await env.notifications.scheduleTestNotification(after: 5)
                                    testSent = testError == nil
                                }
                            } label: { Label(testSent ? "Test sent — check in 5 seconds" : "Send a test notification", systemImage: "paperplane").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).tint(ButlerTheme.ink)
                            .disabled(testSent)
                            if let testError { Text(testError).font(.footnote).foregroundStyle(ButlerTheme.failure) }
                            if testSent { Text("Lock the phone or swipe to the Home Screen to see it arrive.").font(.footnote).foregroundStyle(ButlerTheme.inkSecondary) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .butlerCard()

                    Text("The microphone is used only while you hold the butler's attention; audio is never stored.")
                        .font(.footnote).foregroundStyle(ButlerTheme.inkSecondary).multilineTextAlignment(.center)

                    Button {
                        settings.hasCompletedOnboarding = true
                        dismiss()
                    } label: { Text("Begin").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(ButlerTheme.ink)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboardingBegin")
                }
                .padding(24)
            }
        }
        .task {
            let status = await env.notifications.authorizationStatus()
            if status == .authorized || status == .provisional { notificationsAllowed = true }
            else if status == .denied { notificationsAllowed = false }
        }
    }
}
