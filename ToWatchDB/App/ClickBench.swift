#if DEBUG && os(macOS)
import AppKit
import QuartzCore

/// `-UIClickBench YES` (with `-UISeedSampleData YES -navigationLayout topBar`): clicks the top bar's segments
/// with real mouse events, records every display frame after each click, and writes the longest frame gaps
/// to `<tmp>/clickbench.txt`, then quits. Programmatic tab changes skip the control's press animation, so
/// they don't show the stutter a real click does. Add `-UIClickBenchDirect YES` to set the tab in code instead
/// (no control needed), which separates the page switch from the control's own cost.
@MainActor
enum ClickBench {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "UIClickBench") }

    static weak var appState: AppState?

    static func run() async {
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.toolbar != nil }) else { return finish("no window") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(for: .seconds(1))

        var log = "frame \(window.frame)\n"
        let control = find(NSSegmentedControl.self, in: window.contentView?.superview)
        let direct = UserDefaults.standard.bool(forKey: "UIClickBenchDirect")
        if control == nil && !direct {
            log += dump(window.contentView?.superview, depth: 0)
            return finish(log)
        }
        let recorder = FrameRecorder(view: control ?? window.contentView!)
        // Discover, Next to Watch, Upcoming, Library, Stats, then around again.
        let order = [1, 2, 0, 1, 3, 1, 4, 1, 0, 2, 1] + [3, 0, 1, 2, 4, 1, 3, 2, 0, 1, 4, 2]
        var gaps: [Double] = []
        for segment in order {
            recorder.start()
            if direct || control == nil {
                let tabs: [AppTab] = [.discover, .nextToWatch, .upcoming, .all, .stats, .search]
                try? await Task.sleep(for: .milliseconds(90))
                appState?.selectedTab = tabs[segment]
            } else if let control {
                let point = center(of: segment, in: control)
                post(.leftMouseDown, at: point, in: window)
                try? await Task.sleep(for: .milliseconds(90))
                post(.leftMouseUp, at: point, in: window)
            }
            try? await Task.sleep(for: .milliseconds(900))
            let frames = recorder.stop()
            let deltas = zip(frames.dropFirst(), frames).map { ($0 - $1) * 1000 }
            let worst = deltas.max() ?? 0
            gaps.append(worst)
            let slow = deltas.filter { $0 > 20 }.map { String(format: "%.0f", $0) }.joined(separator: " ")
            log += String(format: "segment %d: %d frames, worst %.0f ms, >20ms: [%@]\n", segment, frames.count, worst, slow)
        }
        let sorted = gaps.sorted()
        log += String(format: "median worst gap %.0f ms, max %.0f ms\n", sorted[sorted.count / 2], sorted.last ?? 0)
        finish(log)
    }

    private static func finish(_ log: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "clickbench.txt")
        try? log.write(to: url, atomically: true, encoding: .utf8)
        print(log)
        NSApp.terminate(nil)
    }

    private static func center(of segment: Int, in control: NSSegmentedControl) -> NSPoint {
        // Use the segments' widths when set; otherwise assume equal widths.
        let fixed = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        let x = fixed.allSatisfy({ $0 > 0 })
            ? fixed.prefix(segment).reduce(0, +) + fixed[segment] / 2
            : control.bounds.width / CGFloat(control.segmentCount) * (CGFloat(segment) + 0.5)
        let local = NSPoint(x: x, y: control.bounds.midY)
        return control.convert(local, to: nil)
    }

    private static func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = find(type, in: subview) { return match } }
        return nil
    }

    private static func dump(_ view: NSView?, depth: Int) -> String {
        guard let view, depth < 14 else { return "" }
        var out = String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame)\n"
        for subview in view.subviews { out += dump(subview, depth: depth + 1) }
        return out
    }
}

/// Collects display-link timestamps for the screen a view is on.
@MainActor
private final class FrameRecorder: NSObject {
    private var link: CADisplayLink?
    private var times: [CFTimeInterval] = []
    private let view: NSView

    init(view: NSView) { self.view = view }

    func start() {
        times = []
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() -> [CFTimeInterval] {
        link?.invalidate()
        link = nil
        return times
    }

    @objc private func tick(_ link: CADisplayLink) { times.append(link.timestamp) }
}
#endif
