import SwiftUI
import Darwin

/// Two screens only: the Butler (home) and My Book (pushed). Everything else is a sheet.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            ButlerView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .book:
                        MyBookView()
                    case .memory(let id):
                        if let m = env.memories.fetch(id: id) { MemoryDetailView(memory: m) } else { Text("Not found") }
                    }
                }
        }
        .tint(ButlerTheme.gold)
        .sheet(isPresented: $router.showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: Binding(get: { !settings.hasCompletedOnboarding && !LaunchOptions.isUITesting }, set: { if !$0 { settings.hasCompletedOnboarding = true } })) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        .safeAreaInset(edge: .top) {
            if let error = env.storeError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(ButlerTheme.failure)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .onAppear { if LaunchOptions.isUITesting { MainThreadWatchdog.start() } }
        .preferredColorScheme(LaunchOptions.forcedColorScheme)
        .dynamicTypeSize(LaunchOptions.forcedTextSize.map { $0...$0 } ?? DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
    }
}

/// Launch arguments used by screenshot tests. Harmless in normal use.
enum LaunchOptions {
    static var arguments: [String] { CommandLine.arguments }
    static var isUITesting: Bool { arguments.contains("-daymind-ui-testing") }

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static var forcedColorScheme: ColorScheme? {
        switch value(after: "-daymind-theme") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    static var forcedTextSize: DynamicTypeSize? {
        switch value(after: "-daymind-textsize") {
        case "xxxl": return .accessibility3
        case "xl": return .xxxLarge
        case "large": return .large
        default: return nil
        }
    }

    /// A request the Butler should process right after launch (deterministic confirmation screenshot).
    static var demoRequest: String? { value(after: "-daymind-demo-request") }
}

/// UI-test-only diagnostic: if the main thread stops answering for a few seconds, print its stack
/// trace to stderr (which the CI test log captures) so hangs can be located precisely.
enum MainThreadWatchdog {
    nonisolated(unsafe) private static var lastPong = Date()
    nonisolated(unsafe) private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        let mainThread = pthread_self()
        signal(SIGUSR1) { _ in
            var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let count = backtrace(&addresses, 64)
            backtrace_symbols_fd(&addresses, count, STDERR_FILENO)
        }
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 1)
                let sent = Date()
                DispatchQueue.main.async { lastPong = Date() }
                Thread.sleep(forTimeInterval: 4)
                if lastPong < sent {
                    fputs("
===== DAYMIND WATCHDOG: main thread unresponsive for 4s; main-thread backtrace follows =====
", stderr)
                    pthread_kill(mainThread, SIGUSR1)
                    Thread.sleep(forTimeInterval: 15)
                }
            }
        }
    }
}
