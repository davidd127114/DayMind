import SwiftUI
import WidgetKit
import AppIntents

@main
struct DayMindControlsBundle: WidgetBundle {
    var body: some Widget {
        TalkControl()
        TalkWidget()
    }
}

/// Control Center / Lock Screen / Action Button control that opens DayMind listening.
struct TalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dabkowski.DayMind.TalkControl") {
            ControlWidgetButton(action: OpenVoiceCaptureIntent()) {
                Label("Talk to DayMind", systemImage: "mic.fill")
            }
        }
        .displayName("Talk to DayMind")
        .description("Opens DayMind and starts listening.")
    }
}

/// Home Screen / Lock Screen widget with a single tap target into voice capture.
struct TalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.dabkowski.DayMind.TalkWidget", provider: TalkTimelineProvider()) { _ in
            TalkWidgetView()
                .widgetURL(OpenVoiceCaptureIntent.deepLink)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Talk to DayMind")
        .description("Tap to open DayMind and speak a reminder or note.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct TalkEntry: TimelineEntry {
    let date: Date
}

struct TalkTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TalkEntry { TalkEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (TalkEntry) -> Void) { completion(TalkEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TalkEntry>) -> Void) {
        completion(Timeline(entries: [TalkEntry(date: Date())], policy: .never))
    }
}

struct TalkWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "mic.fill").font(.title2)
                .accessibilityLabel("Talk to DayMind")
        case .accessoryRectangular:
            Label("Talk to DayMind", systemImage: "mic.fill").font(.headline)
        default:
            VStack(spacing: 8) {
                Image(systemName: "mic.circle.fill").font(.system(size: 44))
                Text("Talk to\nDayMind").font(.headline).multilineTextAlignment(.center)
            }
            .accessibilityLabel("Talk to DayMind")
        }
    }
}
