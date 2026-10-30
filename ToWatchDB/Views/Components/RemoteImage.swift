import ImageIO
import Network
import SwiftUI

/// Decoded TMDB images kept in memory. `AsyncImage` keeps nothing between appearances: every time a page was
/// rebuilt, each poster went back to its placeholder, waited for the URL cache, decoded on the main thread,
/// and faded in again. With this cache a poster seen before draws on the first frame.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// A CGImage behind a class, so it can cross from the decoding task and live in NSCache.
    final class Entry: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        #if os(iOS)
        cache.totalCostLimit = 128 << 20
        #else
        cache.totalCostLimit = 256 << 20
        #endif
        return cache
    }()

    func image(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)?.image
    }

    func store(_ entry: Entry, for url: URL) {
        cache.setObject(entry, forKey: url as NSURL, cost: entry.image.bytesPerRow * entry.image.height)
    }

    /// An answer other than success, which isn't an image. `isFinal` when asking again won't change it: the image
    /// is gone (TMDB answers 404 for a removed poster) rather than the server busy or rate limiting.
    struct BadStatus: Error {
        let code: Int
        var isFinal: Bool { (400..<500).contains(code) && code != 408 && code != 429 }
    }

    /// Downloads in progress, so views showing the same image (a title on two pages, an actor in two casts)
    /// share one download and one decode, with how many are waiting for each.
    private var inFlight: [URL: Download] = [:]
    private let lock = NSLock()

    private struct Download {
        let id: UUID
        let task: Task<Entry, Error>
        var waiters: Int
    }

    /// Fetches (through the shared URL cache) and decodes off the main thread. When every view waiting for a
    /// download is cancelled (scrolled away, page closed), the download is cancelled too: flicking through a grid on
    /// cellular otherwise fetched every poster it passed.
    func load(_ url: URL) async throws -> Entry {
        if let image = image(for: url) { return Entry(image) }
        let (id, task) = lock.withLock {
            if var download = inFlight[url] {
                download.waiters += 1
                inFlight[url] = download
                return (download.id, download.task)
            }
            let id = UUID()
            // Unstructured, so one view scrolling away (cancelling its wait) doesn't cancel the others'.
            let task = Task.detached(priority: .userInitiated) { [self] in
                // Only its own entry: a new download of the URL may have replaced it after a cancellation.
                defer { lock.withLock { if inFlight[url]?.id == id { inFlight[url] = nil } } }
                let (data, response) = try await URLSession.shared.data(from: url)
                if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                    throw BadStatus(code: status)
                }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(
                          source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                      ) else { throw URLError(.cannotDecodeContentData) }
                let entry = Entry(image)
                store(entry, for: url)
                return entry
            }
            inFlight[url] = Download(id: id, task: task, waiters: 1)
            return (id, task)
        }
        // A view that stops waiting while others still wait leaves the download going for them.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            lock.withLock {
                guard var download = inFlight[url], download.id == id else { return }
                download.waiters -= 1
                if download.waiters > 0 {
                    inFlight[url] = download
                } else {
                    inFlight[url] = nil
                    download.task.cancel()
                }
            }
        }
    }
}

/// A remote image backed by `ImageCache`. Cached images appear immediately; only fresh downloads fade in.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    /// Called with `true` while loading, `false` when there's no image to show.
    @ViewBuilder let placeholder: (_ isLoading: Bool) -> Placeholder

    @State private var loaded: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = loaded ?? url.flatMap(ImageCache.shared.image(for:)) {
                content(Image(decorative: image, scale: 1))
            } else {
                placeholder(url != nil && !failed)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            // An image left from a previous URL would keep showing instead of the placeholder.
            loaded = nil
            failed = false
            return
        }
        if ImageCache.shared.image(for: url) != nil {
            // The body already draws it from the cache; only clear an image left from a previous URL.
            if loaded != nil { loaded = nil }
            return
        }
        loaded = nil
        failed = false
        // Offline or timed out: tried again while the image is on screen. It stayed a placeholder until its page
        // was rebuilt, which on Mac (pages kept alive) could be never.
        for retryDelay in [10, 30, 120, nil] as [Int?] {
            do {
                let entry = try await ImageCache.shared.load(url)
                // Waiting on the shared download ignores cancellation: the URL changed meanwhile, and this older
                // image would replace the new one.
                guard !Task.isCancelled else { return }
                failed = false
                withAnimation(.easeOut(duration: 0.15)) { loaded = entry.image }
                return
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                // Scrolled away or the page closed; not a failure.
                return
            } catch let error as ImageCache.BadStatus where error.isFinal {
                // Retried over the next few minutes by every view showing it, it only got the same answer.
                failed = true
                return
            } catch let error as URLError where error.code == .cannotDecodeContentData {
                // The server sent something that isn't an image; sending it again won't help.
                failed = true
                return
            } catch {
                failed = true
            }
            guard let retryDelay else { return }
            do { try await Task.sleep(for: .seconds(retryDelay)) } catch { return }
        }
    }
}

/// Whether the network is in Low Data Mode, for views that can make do with smaller images or none. `URLSession`
/// doesn't use less on its own.
@Observable @MainActor
final class NetworkConditions {
    static let shared = NetworkConditions()

    private(set) var isConstrained = false
    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConstrained = path.isConstrained
            MainActor.assumeIsolated {
                if self?.isConstrained != isConstrained { self?.isConstrained = isConstrained }
            }
        }
        monitor.start(queue: .main)
    }
}
