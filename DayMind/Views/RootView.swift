import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Today", systemImage: "sun.max", value: AppRouter.Tab.today) { TodayView() }
            Tab("Talk", systemImage: "mic.fill", value: AppRouter.Tab.talk) { TalkView() }
            Tab("Memories", systemImage: "brain.head.profile", value: AppRouter.Tab.memories) { MemoriesView() }
            Tab("Projects", systemImage: "folder", value: AppRouter.Tab.projects) { ProjectsView() }
            Tab("Inbox", systemImage: "tray", value: AppRouter.Tab.inbox) { InboxView() }
                .badge(env.inbox.unresolvedCount)
        }
        .sheet(isPresented: $router.showSettings) {
            NavigationStack { SettingsView() }
        }
        .safeAreaInset(edge: .top) {
            if let error = env.storeError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red)
            }
        }
    }
}

/// Toolbar gear that opens Settings from every top-level screen.
struct SettingsToolbarButton: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { SettingsGearButton() }
    }
}

struct SettingsGearButton: View {
    @Environment(AppRouter.self) private var router
    var body: some View {
        Button { router.showSettings = true } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
    }
}
