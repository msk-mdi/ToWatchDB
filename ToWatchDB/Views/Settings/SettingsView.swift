import AuthenticationServices
import SwiftData
import SwiftUI
import ToWatchCore

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(NavigationLayout.storageKey) private var layout: NavigationLayout = .sidebar
    @AppStorage(ThemeColor.accentKey) private var accent: ThemeColor = .coral
    @AppStorage(ThemeColor.appIconKey) private var appIcon: ThemeColor = .coral
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    @State private var tokenDraft = ""
    /// Settings runs its own panels: on macOS it's a separate window from the one handling File menu requests.
    @State private var fileRequest: LibraryFileRequest?
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var seerrServerDraft = ""
    @State private var seerrKeyDraft = ""
    @State private var seerrUserDraft = ""
    @State private var seerrPasswordDraft = ""
    @State private var seerrMethod = SeerrSignInMethod.jellyfin
    @State private var seerrTestResult: String?
    @State private var isTestingSeerr = false
    #if os(macOS)
    @State private var formWidth: CGFloat = 0
    #endif

    private static let languages: [(code: String, name: String)] = [
        ("", "System Default"), ("en-US", "English"), ("fr-FR", "Français"), ("es-ES", "Español"),
        ("de-DE", "Deutsch"), ("it-IT", "Italiano"), ("pt-BR", "Português (Brasil)"), ("nl-NL", "Nederlands"),
        ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("zh-CN", "中文 (简体)"), ("ar-SA", "العربية"),
    ]

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section {
                if hasLayoutChoice {
                    Picker("Navigation", selection: $layout) {
                        ForEach(NavigationLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                AppearanceRow("Accent Color") { ThemeSwatches(selection: $accent) }
                AppearanceRow("App Icon") { AppIconPicker(selection: $appIcon) }
            } header: {
                Text("Appearance")
            } footer: {
                #if os(macOS)
                Text("macOS shows the chosen icon in the Dock while ToWatchDB is open; Finder keeps the original icon.")
                #endif
            }

            Section {
                LabeledContent("Access Token") {
                    Text(tokenStatus).foregroundStyle(appState.token == nil ? .red : .secondary)
                }
                SecureField("Read access token", text: $tokenDraft, prompt: Text("Paste your API Read Access Token"))
                HStack {
                    Button("Save Token") {
                        appState.setTokenOverride(tokenDraft)
                        tokenDraft = ""
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if appState.tokenOverride != nil {
                        Button("Remove Token", role: .destructive) { appState.setTokenOverride(nil) }
                    }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button("Test Connection") { test() }
                        .disabled(appState.client == nil || isTesting)
                }
                .rowButtonStyle()
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(.secondary)
                }
                Picker("Language", selection: $appState.language) {
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                Text("Titles, overviews, and episode names are fetched in this language when TMDB has a translation. Refresh the library to update existing titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Where to Watch Country", selection: $appState.watchRegion) {
                    ForEach(Self.regions, id: \.self) { code in
                        Text(Locale.current.localizedString(forRegionCode: code) ?? code).tag(code)
                    }
                }
            } header: {
                Text("TMDB")
            } footer: {
                // Release builds ship without a token, so this is where every new user starts.
                Link("Get a free API Read Access Token at themoviedb.org", destination: TMDBLinks.apiSettings)
            }

            seerrSection

            Section("Library") {
                // Counted in the store instead of loading every title; recounted after each save.
                let counts = appState.cached("library-counts") {
                    ((try? context.fetchCount(FetchDescriptor<Movie>())) ?? 0,
                     (try? context.fetchCount(FetchDescriptor<TVShow>())) ?? 0)
                }
                LabeledContent("Movies", value: counts.0.formatted())
                LabeledContent("TV Shows", value: counts.1.formatted())
                HStack {
                    Button("Refresh All Titles") { Task { await appState.refreshLibrary(force: true) } }
                        .disabled(appState.isRefreshing || appState.client == nil)
                    if appState.isRefreshing { ProgressView().controlSize(.small) }
                }
                .rowButtonStyle()
                Text("Ongoing shows and unreleased movies refresh automatically every 12 hours at launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                #if os(iOS)
                Button("Export Backup…", systemImage: "square.and.arrow.up") { fileRequest = .exportBackup }
                Button("Export as CSV…", systemImage: "tablecells") { fileRequest = .exportCSV }
                Button("Import Backup…", systemImage: "square.and.arrow.down") { fileRequest = .importBackup }
                Button("Import List of Titles…", systemImage: "list.bullet") { fileRequest = .importList }
                #else
                HStack {
                    Button("Export Backup…") { fileRequest = .exportBackup }
                    Button("Export as CSV…") { fileRequest = .exportCSV }
                    Spacer()
                    Button("Import List…") { fileRequest = .importList }
                    Button("Import Backup…") { fileRequest = .importBackup }
                }
                #endif
            } header: {
                Text("Backup")
            } footer: {
                Text("A backup holds your whole library: titles, watch history, ratings, notes, spaces, tags, and smart lists. Importing merges into what's here, so nothing is lost or duplicated. CSV is for spreadsheets and can't be imported. A list of titles (a text file with one per line, like “Arrival (2016)”) can be imported: each title is looked up on TMDB.")
            }

            dropboxSection

            Section("About") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ToWatchDB").font(.headline)
                        Text("This product uses the TMDB API but is not endorsed or certified by TMDB.")
                            .font(.callout)
                        Link("themoviedb.org", destination: URL(string: "https://www.themoviedb.org")!)
                            .font(.callout)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .libraryFileTransfers($fileRequest)
        #if os(macOS)
        // The window opens filling the screen. The form keeps a readable width in the middle, while the
        // scroll view (and its scroll bar) spans the window.
        .scrollIndicators(.visible)
        .contentMargins(.horizontal, max(0, (formWidth - 760) / 2), for: .scrollContent)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { formWidth = $0 }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(SettingsWindowSetup())
        #else
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
    }

    @ViewBuilder
    private var dropboxSection: some View {
        let dropbox = appState.dropbox
        Section {
            if dropbox.client == nil {
                Text("This build has no Dropbox app key. Set DROPBOX_APP_KEY in Config/Secrets.xcconfig to turn on sync.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if dropbox.isConnected {
                LabeledContent("Account", value: dropbox.accountEmail ?? "Connected")
                LabeledContent("Last Synced") {
                    if dropbox.isSyncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(dropbox.lastSynced?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    }
                }
                HStack {
                    Button("Sync Now") { appState.syncWithDropbox() }
                        .disabled(dropbox.isSyncing)
                    Spacer()
                    Button("Disconnect", role: .destructive) { dropbox.disconnect() }
                }
                .rowButtonStyle()
            } else {
                Button("Connect Dropbox…") { connectDropbox() }
            }
            if let error = dropbox.lastError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Dropbox Sync")
        } footer: {
            Text("Keeps your library, backlog, watch history, ratings, notes, spaces, tags, and smart lists the same on every device connected to the same Dropbox. It's stored in Dropbox ▸ Apps ▸ ToWatchDB, and syncs when the app opens and a few seconds after each change. Disconnecting keeps everything on this device and in Dropbox.")
        }
    }

    @ViewBuilder
    private var seerrSection: some View {
        Section {
            if let seerr = appState.seerr {
                LabeledContent("Server", value: seerr.baseURL.absoluteString)
                LabeledContent("Signed In As") {
                    switch seerr.auth {
                    case .apiKey: Text("API key (admin)")
                    case .session: Text(appState.seerrUserName ?? "Your account")
                    }
                }
                HStack {
                    Button("Test Connection") { testSeerr() }
                        .disabled(isTestingSeerr)
                    if isTestingSeerr { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sign Out", role: .destructive) { signOutOfSeerr() }
                }
                .rowButtonStyle()
            } else {
                TextField("Server", text: $seerrServerDraft, prompt: Text("http://192.168.1.10:5055"))
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                Picker("Sign In With", selection: $seerrMethod) {
                    ForEach(SeerrSignInMethod.allCases) { Text($0.label).tag($0) }
                }
                switch seerrMethod {
                case .jellyfin, .seerr:
                    TextField(seerrMethod == .seerr ? "Email" : "Username", text: $seerrUserDraft)
                        #if os(iOS)
                        .textContentType(seerrMethod == .seerr ? .emailAddress : .username)
                        .keyboardType(seerrMethod == .seerr ? .emailAddress : .default)
                        .textInputAutocapitalization(.never)
                        #else
                        .textContentType(.username)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Password", text: $seerrPasswordDraft)
                        .textContentType(.password)
                case .apiKey:
                    SecureField("API Key", text: $seerrKeyDraft, prompt: Text("Paste your Seerr API key"))
                }
                HStack {
                    Button("Sign In") { connectSeerr() }
                        .disabled(isTestingSeerr || !canConnectSeerr)
                    if isTestingSeerr { ProgressView().controlSize(.small) }
                }
                .rowButtonStyle()
            }
            if let seerrTestResult {
                Text(seerrTestResult).font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Seerr")
        } footer: {
            Text("Request movies and shows on your Seerr, Overseerr, or Jellyseerr server from any title's page. Sign in with the Jellyfin or Emby account you use on Seerr, or a Seerr account: requests are made as you, with your permissions, and your password isn't stored. Seerr signs you out after 30 days. An API key (Seerr ▸ Settings ▸ General) acts as the server's admin and doesn't expire. Plain http works only for addresses on your local network.")
        }
    }

    private var canConnectSeerr: Bool {
        let filled = { (text: String) in !text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard filled(seerrServerDraft) else { return false }
        return seerrMethod == .apiKey ? filled(seerrKeyDraft) : filled(seerrUserDraft) && !seerrPasswordDraft.isEmpty
    }

    /// Checks the address and sign-in before saving them, so a typo doesn't leave a server that never answers.
    private func connectSeerr() {
        isTestingSeerr = true
        seerrTestResult = nil
        let server = seerrServerDraft, user = seerrUserDraft.trimmingCharacters(in: .whitespaces)
        let password = seerrPasswordDraft, key = seerrKeyDraft, method = seerrMethod
        Task {
            do {
                let (client, account): (SeerrClient, SeerrUser)
                switch method {
                case .apiKey:
                    guard let keyClient = SeerrClient(server: server, apiKey: key) else { throw SeerrError.invalidServer }
                    (client, account) = (keyClient, try await keyClient.currentUser())
                case .jellyfin:
                    (client, account) = try await SeerrClient.signIn(server: server, with: .jellyfin(username: user, password: password))
                case .seerr:
                    (client, account) = try await SeerrClient.signIn(server: server, with: .seerr(email: user, password: password))
                }
                appState.setSeerr(client, userName: account.name)
                seerrServerDraft = ""
                seerrUserDraft = ""
                seerrPasswordDraft = ""
                seerrKeyDraft = ""
                seerrTestResult = "Signed in as \(account.name)."
            } catch {
                seerrTestResult = error.localizedDescription
            }
            isTestingSeerr = false
        }
    }

    private func testSeerr() {
        guard let client = appState.seerr else { return }
        isTestingSeerr = true
        seerrTestResult = nil
        Task {
            do {
                seerrTestResult = "Connected as \(try await client.currentUser().name)."
            } catch {
                seerrTestResult = error.localizedDescription
            }
            isTestingSeerr = false
        }
    }

    private func signOutOfSeerr() {
        let client = appState.seerr
        appState.setSeerr(nil)
        seerrTestResult = nil
        // Ends the session on the server too; forgetting it here is what matters if that fails.
        Task { try? await client?.signOut() }
    }

    private func connectDropbox() {
        Task {
            await appState.dropbox.connect { url, scheme in
                try await webAuthenticationSession.authenticate(using: url, callback: .customScheme(scheme),
                                                                preferredBrowserSession: nil, additionalHeaderFields: [:])
            }
            appState.syncWithDropbox()
        }
    }

    /// Every ISO country, sorted by localized name, for the Where to Watch default.
    private static let regions: [String] = Locale.Region.isoRegions
        .filter { $0.subRegions.isEmpty && $0.identifier.count == 2 && $0.identifier.allSatisfy(\.isLetter) }
        .map(\.identifier)
        .sorted {
            (Locale.current.localizedString(forRegionCode: $0) ?? $0)
                .localizedStandardCompare(Locale.current.localizedString(forRegionCode: $1) ?? $1) == .orderedAscending
        }

    /// iPhone always uses its tab bar; Mac and iPad can choose.
    private var hasLayoutChoice: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    private var tokenStatus: String {
        if appState.tokenOverride != nil {
            #if os(macOS)
            return "Saved, encrypted"
            #else
            return "Saved in Keychain"
            #endif
        }
        if appState.hasBundledToken { return "Built-in token" }
        return "Missing"
    }

    private func test() {
        guard let client = appState.client else { return }
        isTesting = true
        testResult = nil
        Task {
            do {
                let page = try await client.trendingMovies()
                testResult = "Connected. \(page.results.count) trending movies received."
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}

private enum SeerrSignInMethod: String, CaseIterable, Identifiable {
    case jellyfin, seerr, apiKey
    var id: Self { self }
    var label: String {
        switch self {
        case .jellyfin: "Jellyfin or Emby"
        case .seerr: "Seerr Account"
        case .apiKey: "API Key"
        }
    }
}

private extension View {
    /// In an iOS Form, a row with several buttons fires all of them on tap unless they're borderless.
    func rowButtonStyle() -> some View {
        #if os(iOS)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }
}

/// Label beside the control on macOS, above it on iOS where rows are narrow.
private struct AppearanceRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        #if os(macOS)
        LabeledContent(title) { content }
        #else
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
            content
        }
        .padding(.vertical, 4)
        #endif
    }
}

/// A row of theme colors to choose from.
private struct ThemeSwatches: View {
    @Binding var selection: ThemeColor

    var body: some View {
        #if os(macOS)
        HStack(spacing: 8) { swatches }
        #else
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 4)], spacing: 6) { swatches }
        #endif
    }

    private var swatches: some View {
        Group {
            ForEach(ThemeColor.allCases) { theme in
                Button { selection = theme } label: {
                    Circle()
                        .fill(theme.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if selection == theme {
                                Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                            }
                        }
                        .padding(3)
                        .overlay { Circle().strokeBorder(theme.color, lineWidth: selection == theme ? 2 : 0) }
                }
                .buttonStyle(.plain)
                .help(theme.label)
                .accessibilityLabel(theme.label)
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
    }
}

/// The app icon in each theme color.
private struct AppIconPicker: View {
    @Binding var selection: ThemeColor

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 60), spacing: 8)], spacing: 8) {
            ForEach(ThemeColor.allCases) { theme in
                Button { selection = theme } label: {
                    Image(theme.iconPreviewName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .padding(2)
                        .background {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.tint, lineWidth: selection == theme ? 2.5 : 0)
                        }
                }
                .buttonStyle(.plain)
                .help(theme.label)
                .accessibilityLabel("\(theme.label) icon")
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
        #if os(macOS)
        .frame(width: 320)
        #endif
    }
}

#if os(macOS)
/// Sets up the Settings window, which SwiftUI doesn't expose:
/// - It fills the screen (all but the menu bar and Dock) each time it opens, and can be resized.
/// - With "Show scroll bars: Automatically" (the default with a trackpad), macOS hides scroll bars until you
///   scroll, even with `.scrollIndicators(.visible)`. The form keeps a classic, always-visible scroll bar.
private struct SettingsWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        /// Set when the window closes: SwiftUI keeps the window and its views for the next time it opens.
        private var fillsOnNextShow = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            window.styleMask.insert(.resizable)
            center.addObserver(self, selector: #selector(windowDidBecomeKey),
                               name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillClose),
                               name: NSWindow.willCloseNotification, object: window)
            // macOS resets the scroll bar style when the system preference changes.
            center.addObserver(self, selector: #selector(applyScrollBarStyle),
                               name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
            // The form's scroll view is built alongside this background view; style it once both exist.
            DispatchQueue.main.async { [weak self] in
                self?.applyScrollBarStyle()
                self?.fillScreenIfNeeded()
            }
        }

        @objc private func windowDidBecomeKey() { fillScreenIfNeeded() }
        @objc private func windowWillClose() { fillsOnNextShow = true }

        private func fillScreenIfNeeded() {
            guard fillsOnNextShow, let window, let screen = window.screen ?? NSScreen.main else { return }
            fillsOnNextShow = false
            window.setFrame(screen.visibleFrame, display: true, animate: false)
        }

        @objc private func applyScrollBarStyle() {
            guard let root = window?.contentView else { return }
            for scrollView in Self.scrollViews(in: root) {
                scrollView.scrollerStyle = .legacy
                scrollView.hasVerticalScroller = true
                scrollView.autohidesScrollers = true // Only when everything fits.
            }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
    }
}
#else
private struct SettingsWindowSetup: View {
    var body: some View { EmptyView() }
}
#endif
