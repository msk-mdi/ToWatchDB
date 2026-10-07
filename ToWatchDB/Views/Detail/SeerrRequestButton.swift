import SwiftUI
import ToWatchCore

/// Requests the title on the user's Seerr server, or says where it stands there: Request on Seerr (or Request
/// More Seasons), Requested on Seerr, or Watch Now once it's on the media server, with a Delete Request button
/// beside it. Shows nothing until a server is set up in Settings, or while Seerr can't be reached. A movie is
/// requested in one click; a show opens a season picker.
struct SeerrRequestButton: View {
    @Environment(AppState.self) private var appState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let kind: MediaSummary.Kind
    let tmdbID: Int
    let title: String

    @State private var status: SeerrTitle?
    @State private var isRequesting = false
    @State private var isPickingSeasons = false
    /// Bumped after a request or deletion, to load the new status (and keep checking it).
    @State private var watchGeneration = 0
    @State private var deleting: SeerrRequest?

    var body: some View {
        if let seerr = appState.seerr {
            // iPhone: full-width buttons, one per line. Mac and iPad: one row.
            let layout = isCompact ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                if let status {
                    button(seerr, status)
                    deleteButtons(status)
                }
            }
            .fixedSize(horizontal: !isCompact, vertical: false)
            .buttonStyle(.bordered)
            .modifier(CompactWidth(isCompact: isCompact))
            .task(id: "\(seerr.baseURL)|\(seerr.auth.hashValue)|\(kind.rawValue)-\(tmdbID)|\(watchGeneration)") {
                await watch(seerr)
            }
            .confirmationDialog("Delete the request for “\(title)”?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                presenting: deleting) { request in
                Button("Delete Request", role: .destructive) { delete(seerr, request) }
            } message: { request in
                Text(request.isApproved
                     ? "It's already approved. Seerr forgets the request, but a download Radarr or Sonarr already started keeps going."
                     : "Seerr forgets the request before anyone approves it.")
            }
            .sheet(isPresented: $isPickingSeasons) {
                if let status {
                    SeerrSeasonSheet(showTitle: title, seerrTitle: status) { request(seerr, seasons: $0) }
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ seerr: SeerrClient, _ status: SeerrTitle) -> some View {
        if canRequest(status) {
            Button {
                if kind == .tv { isPickingSeasons = true } else { request(seerr, seasons: []) }
            } label: {
                // The page's text color: dark with white text, or white with dark text in Dark Mode.
                Label(requestLabel(status), systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.background)
            }
            .buttonStyle(.borderedProminent)
            .tint(.primary)
            .disabled(isRequesting)
            .help("Request “\(title)” on \(seerr.baseURL.host() ?? "Seerr")")
        } else if status.availability == .available || status.availability == .partiallyAvailable,
                  let url = status.mediaURL {
            Link(destination: url) { Label("Watch Now", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .help("Open “\(title)” on your media server")
        } else if status.isInProgress {
            Button {} label: { Label("Requested on Seerr", systemImage: "clock") }
                .disabled(true)
        }
    }

    /// One red button per request (a show can have several, for different seasons).
    @ViewBuilder
    private func deleteButtons(_ status: SeerrTitle) -> some View {
        ForEach(status.requests) { request in
            Button { deleting = request } label: {
                Label(deleteLabel(request, among: status.requests), systemImage: "trash")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isRequesting)
            .help("Delete the request on Seerr")
        }
    }

    private func deleteLabel(_ request: SeerrRequest, among requests: [SeerrRequest]) -> String {
        var label = "Delete Request"
        if kind == .tv, !request.seasons.isEmpty {
            label += request.seasons.count == 1 ? " for Season \(request.seasons[0])"
                : " for Seasons \(request.seasons.map(String.init).formatted())"
        }
        if requests.count > 1, let name = request.requestedBy { label += " (\(name))" }
        return label
    }

    private func canRequest(_ status: SeerrTitle) -> Bool {
        switch kind {
        case .movie: status.availability == .requestable
        // A show Seerr has no seasons for (not on TMDB yet) can't be requested season by season.
        case .tv: !status.requestableSeasons.isEmpty
        }
    }

    private func requestLabel(_ status: SeerrTitle) -> String {
        if kind == .tv, status.seasons.contains(where: { $0.availability != .requestable }) { return "Request More Seasons" }
        return "Request on Seerr"
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// Loads the status, then checks it every 30 seconds while a request is in progress, so Requested turns
    /// into Watch Now when the title arrives. Stops with the page. Hidden when Seerr can't be reached.
    private func watch(_ seerr: SeerrClient) async {
        while !Task.isCancelled {
            do {
                status = try await seerr.title(kind == .movie ? .movie : .tv, tmdbID: tmdbID)
            } catch is CancellationError {
                return
            } catch {
                status = nil
                return
            }
            guard status?.isInProgress == true else { return }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func delete(_ seerr: SeerrClient, _ request: SeerrRequest) {
        isRequesting = true
        Task {
            do {
                try await seerr.deleteRequest(id: request.id)
                watchGeneration += 1
            } catch {
                appState.errorMessage = error.localizedDescription
            }
            isRequesting = false
        }
    }

    private func request(_ seerr: SeerrClient, seasons: [Int]) {
        isRequesting = true
        Task {
            do {
                try await seerr.request(kind == .movie ? .movie : .tv, tmdbID: tmdbID, seasons: seasons)
                watchGeneration += 1
            } catch {
                appState.errorMessage = error.localizedDescription
            }
            isRequesting = false
        }
    }
}

/// iPhone: a full-width button like the rest of the page's actions.
private struct CompactWidth: ViewModifier {
    let isCompact: Bool

    func body(content: Content) -> some View {
        if isCompact {
            content.labelStyle(WideLabelStyle()).controlSize(.large)
        } else {
            content
        }
    }
}

/// Picks which seasons of a show to request. Seasons already requested or available are listed but can't be picked.
private struct SeerrSeasonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let showTitle: String
    let seerrTitle: SeerrTitle
    let onRequest: ([Int]) -> Void

    @State private var selected: Set<Int> = []

    var body: some View {
        let requestable = Set(seerrTitle.requestableSeasons.map(\.number))
        NavigationStack {
            Form {
                Section {
                    Toggle("All Seasons", isOn: Binding(
                        get: { selected == requestable },
                        set: { selected = $0 ? requestable : [] }
                    ))
                    .bold()
                    ForEach(seerrTitle.seasons) { season in
                        if season.availability == .requestable {
                            Toggle(isOn: Binding(
                                get: { selected.contains(season.number) },
                                set: { if $0 { selected.insert(season.number) } else { selected.remove(season.number) } }
                            )) {
                                seasonLabel(season)
                            }
                        } else {
                            LabeledContent {
                                Text(statusText(season.availability))
                            } label: {
                                seasonLabel(season)
                            }
                        }
                    }
                } footer: {
                    Text("Only seasons nobody has requested yet can be picked.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Request “\(showTitle)”")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.count > 1 ? "Request \(selected.count) Seasons" : "Request") {
                        onRequest(selected.sorted())
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .onAppear { selected = requestable }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    private func seasonLabel(_ season: SeerrSeason) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(season.name)
            if let count = season.episodeCount {
                Text("\(count) episode\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(_ availability: SeerrAvailability) -> String {
        switch availability {
        case .available: "Available"
        case .partiallyAvailable: "Partly available"
        case .requested: "Requested"
        case .blocked: "Blocked"
        case .requestable: ""
        }
    }
}
