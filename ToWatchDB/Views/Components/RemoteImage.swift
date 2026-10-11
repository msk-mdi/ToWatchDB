import ImageIO
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

    /// Downloads in progress, so views showing the same image (a title on two pages, an actor in two casts)
    /// share one download and one decode. `waiters` counts the views waiting for it.
    private var inFlight: [URL: (id: UUID, task: Task<Entry, Error>, waiters: Int)] = [:]
    private let lock = NSLock()

    /// Fetches (through the shared URL cache) and decodes off the main thread.
    func load(_ url: URL) async throws -> Entry {
        if let image = image(for: url) { return Entry(image) }
        let (id, task) = lock.withLock {
            if let flight = inFlight[url] {
                inFlight[url]?.waiters += 1
                return (flight.id, flight.task)
            }
            let id = UUID()
            // Unstructured, so one view scrolling away (cancelling its wait) doesn't cancel the others'.
            let task = Task.detached(priority: .userInitiated) { [self] in
                // Only its own entry: a cancelled download's entry may already be replaced by a new one.
                defer { lock.withLock { if inFlight[url]?.id == id { inFlight[url] = nil } } }
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(
                          source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                      ) else { throw URLError(.cannotDecodeContentData) }
                let entry = Entry(image)
                store(entry, for: url)
                return entry
            }
            inFlight[url] = (id, task, 1)
            return (id, task)
        }
        // A download every view stopped waiting for (scrolled past) is cancelled: when scrolling fast through a
        // grid, finishing them all delayed the posters now on screen.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            lock.withLock {
                guard let flight = inFlight[url], flight.id == id else { return }
                if flight.waiters > 1 {
                    inFlight[url]?.waiters -= 1
                } else {
                    flight.task.cancel()
                    inFlight[url] = nil
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
        do {
            let entry = try await ImageCache.shared.load(url)
            // Waiting on the shared download ignores cancellation: the URL changed meanwhile, and this older
            // image would replace the new one.
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { loaded = entry.image }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
            // Scrolled away or the page closed; not a failure.
        } catch {
            failed = true
        }
    }
}
