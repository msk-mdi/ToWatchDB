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

    /// An answer other than success, which isn't an image. `isFinal` when asking again won't change it: the image
    /// is gone (TMDB answers 404 for a removed poster) rather than the server busy or rate limiting.
    struct BadStatus: Error {
        let code: Int
        var isFinal: Bool { (400..<500).contains(code) && code != 408 && code != 429 }
    }

    /// Downloads in progress, so views showing the same image (a title on two pages, an actor in two casts)
    /// share one download and one decode.
    private var inFlight: [URL: Task<Entry, Error>] = [:]
    private let lock = NSLock()

    /// Fetches (through the shared URL cache) and decodes off the main thread.
    func load(_ url: URL) async throws -> Entry {
        if let image = image(for: url) { return Entry(image) }
        let task = lock.withLock {
            if let task = inFlight[url] { return task }
            // Unstructured, so one view scrolling away (cancelling its wait) doesn't cancel the others'.
            let task = Task.detached(priority: .userInitiated) { [self] in
                defer { lock.withLock { inFlight[url] = nil } }
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
            inFlight[url] = task
            return task
        }
        // A download that a view stops waiting for (scrolled away) still finishes into the cache, so scrolling
        // back finds it.
        return try await task.value
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
