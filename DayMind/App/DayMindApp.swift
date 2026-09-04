import SwiftUI
import SwiftData

@main
struct DayMindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var env = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(env.router)
                .environment(env.settings)
                .modelContainer(env.store.container)
                .task { await env.onLaunch() }
                .onOpenURL { url in env.router.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await env.onForeground() }
            } else if phase == .background {
                env.voice.stopEverything(reason: "background")
            }
        }
    }
}
