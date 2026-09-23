import SwiftUI
import ToWatchCore

extension WatchStatus {
    var symbol: String {
        switch self {
        case .notWatched: "circle"
        case .watching: "play.circle.fill"
        case .watched: "checkmark.circle.fill"
        case .abandoned: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notWatched: .secondary
        case .watching: .orange
        case .watched: .green
        case .abandoned: .red
        }
    }
}

/// Small status glyph drawn over a poster corner.
struct StatusBadge: View {
    let status: WatchStatus

    var body: some View {
        if status != .notWatched {
            Image(systemName: status.symbol)
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, status.tint)
                .shadow(radius: 2)
                .accessibilityLabel(status.label)
        }
    }
}

/// Chip used for genres and metadata.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
    }
}

extension Date {
    var yearString: String { formatted(Date.FormatStyle(timeZone: .gmt).year()) }
    /// TMDB dates are UTC calendar days; format them in UTC so they don't shift a day.
    var tmdbDayString: String {
        formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
    }
}

extension Int {
    /// 148 → "2h 28m"
    var runtimeString: String {
        Duration.seconds(self * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
