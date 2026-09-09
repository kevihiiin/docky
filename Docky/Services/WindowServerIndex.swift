//
//  WindowServerIndex.swift
//  Docky
//
//  What windows exist, per process, per Mission Control space -- taken from
//  the WindowServer rather than from Accessibility.
//
//  `WindowRegistry` is built by walking `kAXWindowsAttribute`, and for many
//  applications AX simply does not report windows that live on another space.
//  Measured on a normal desktop: 17 live windows on other spaces, all of them
//  ordinary layer-0 windows large enough to pass every filter the registry
//  applies, and none of them present in the registry. That is not a filtering
//  bug -- AX never mentioned them.
//
//  The consequence is that nothing built by filtering the registry can answer
//  "does this app have a window on some other desktop?", because from the
//  registry's point of view such an app has no windows at all, which is
//  indistinguishable from not running.
//
//  This index fills that gap. It deliberately does NOT try to make AX see
//  more, and it does not replace the registry: AX is still the only way to
//  focus, minimize, close or move a window, and the registry remains the
//  authority on windows that can be acted upon. This is the weaker but
//  broader claim -- these windows exist, this process owns them, they sit on
//  these spaces -- which is exactly what space-aware decisions need.
//
//  Main-thread published, background-scanned: see `refresh()`.
//

import AppKit
import Combine
import Foundation

/// A window as the WindowServer sees it. May have no `AXUIElement` at all --
/// that is the point of this type, and the reason it is not an `AppWindow`.
struct ServerWindow: Hashable, Identifiable {
    let cgWindowID: CGWindowID
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let title: String?
    let frame: CGRect

    /// Minimized windows are ordered out but keep their space membership.
    /// Windows merely on another space stay ordered in.
    let isMinimized: Bool

    /// Every space this window is resident on. Never empty: an empty set is
    /// how a dead window is recognised, so those are dropped during indexing.
    let spaces: Set<CGSSpaceID>

    var id: CGWindowID { cgWindowID }
}

final class WindowServerIndex: ObservableObject {
    static let shared = WindowServerIndex()

    /// Every live, ordinary application window the WindowServer knows about,
    /// including ones on other spaces and minimized ones.
    @Published private(set) var windows: [ServerWindow] = []

    /// Bumped on each accepted scan. Lets a consumer notice it is holding a
    /// stale derivation without comparing the whole array.
    @Published private(set) var generation: UInt64 = 0

    private var byBundleIdentifier: [String: [ServerWindow]] = [:]

    /// Scanning happens off the main thread.
    ///
    /// A full scan measures 4-8ms (median 5), and essentially all of it is
    /// `CGWindowListCopyWindowInfo` for *all* windows: that call alone is
    /// 5-19ms against 0.4ms for the on-screen subset. The cheap variant is not
    /// an option, because off-screen windows are exactly what this index
    /// exists to find. The per-window space and ordered-in lookups are ~30us
    /// and ~24us and only run for windows that survive the owner and size
    /// filters, so they contribute well under a millisecond.
    ///
    /// Milliseconds on the main thread during a space switch would be a
    /// visible hitch -- `WindowRegistry.rebuildSnapshot` already spends
    /// several there re-walking AX -- so the scan is dispatched and the result
    /// published back on main. The first scan of a session costs noticeably
    /// more (~30ms) while dlsym resolves the SkyLight symbols and the window
    /// list warms; that one happens at startup, off the main thread, before
    /// anything consumes the index.
    private let scanQueue = DispatchQueue(label: "gt.quintero.Docky.WindowServerIndex", qos: .userInitiated)

    /// Guards against an older scan landing after a newer one.
    private var issuedScan: UInt64 = 0
    private var appliedScan: UInt64 = 0

    private var observers: [NSObjectProtocol] = []
    private var isStarted = false
    private var pendingRefresh: DispatchWorkItem?

    /// Supplies pid -> bundle identifier for the processes worth indexing.
    ///
    /// Injected rather than read from `WorkspaceService` so this file has no
    /// dependency on the Accessibility side of the app: the scan stays a pure
    /// function of its inputs and can be exercised on its own. It also puts
    /// the "which processes count" policy in one place -- passing
    /// `WorkspaceService`'s cache means regular-activation-policy filtering
    /// and Docky's self-exclusion are inherited rather than duplicated.
    private var owners: () -> [pid_t: String] = { [:] }

    /// Matches `WindowRegistry.minimumTrackedWindowSize`: below this a window
    /// is an overlay, a tooltip or a menu-bar strip rather than content.
    private static let minimumSize = CGSize(width: 100, height: 100)

    /// Same exclusions `WindowRegistry` applies, by bundle identifier. These
    /// processes own layer-0 windows that are not application windows.
    private static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.dock"
    ]

    /// Coalescing window for bursts. A single user action -- switching space,
    /// launching an app -- can fire several notifications at once.
    private static let coalesceInterval: TimeInterval = 0.15

    private init() {}

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Begins tracking. `owners` is consulted on every scan; pass a closure
    /// over whatever processes the caller considers real applications.
    func start(owners: @escaping () -> [pid_t: String]) {
        self.owners = owners
        guard !isStarted else {
            refresh()
            return
        }
        isStarted = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didWakeNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleRefresh()
            })
        }

        refresh()
    }

    /// Coalesced entry point for notification-driven refreshes.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: work)
    }

    // MARK: - Queries

    func windows(ofBundleIdentifier bundleIdentifier: String) -> [ServerWindow] {
        byBundleIdentifier[bundleIdentifier] ?? []
    }

    func windows(ofBundleIdentifier bundleIdentifier: String, on space: SpaceIdentity) -> [ServerWindow] {
        windows(ofBundleIdentifier: bundleIdentifier).filter { $0.spaces.contains(space.id) }
    }

    func hasWindow(ofBundleIdentifier bundleIdentifier: String, on space: SpaceIdentity) -> Bool {
        windows(ofBundleIdentifier: bundleIdentifier).contains { $0.spaces.contains(space.id) }
    }

    /// Whether the app owns a live window that is not on `space`.
    ///
    /// This is the question `WorkspaceService.activateOrOpen` needs and cannot
    /// currently answer. Unlike the existing `SLSWindowIsOrderedIn` check it
    /// also counts windows minimized on another space, which are ordered out
    /// and were therefore being missed.
    func hasWindowElsewhere(ofBundleIdentifier bundleIdentifier: String, excluding space: SpaceIdentity) -> Bool {
        windows(ofBundleIdentifier: bundleIdentifier).contains { !$0.spaces.contains(space.id) }
    }

    /// Bundle identifiers with at least one window on `space`.
    func bundleIdentifiers(on space: SpaceIdentity) -> Set<String> {
        var result: Set<String> = []
        for window in windows where window.spaces.contains(space.id) {
            result.insert(window.bundleIdentifier)
        }
        return result
    }

    // MARK: - Scanning

    func refresh() {
        // The owner map is read on the main thread because its usual source
        // is main-thread state. Re-enumerating
        // `NSWorkspace.runningApplications` on the scan queue instead
        // measured 8-13ms, more than the window scan itself.
        let snapshot = owners()

        issuedScan &+= 1
        let scan = issuedScan

        scanQueue.async { [weak self] in
            guard let self else { return }
            let scanned = Self.scan(owners: snapshot)
            DispatchQueue.main.async {
                self.apply(scanned, scan: scan)
            }
        }
    }

    /// Synchronous variant, for decision points that must not act on a stale
    /// answer -- a dock click deciding whether to switch space or open a new
    /// window. Costs the full 4-8ms scan on the calling thread, which is
    /// acceptable once per click and not acceptable on a redraw path.
    func refreshNow() {
        issuedScan &+= 1
        apply(Self.scan(owners: owners()), scan: issuedScan)
    }

    private func apply(_ scanned: [ServerWindow], scan: UInt64) {
        // Drop a scan that was overtaken while it was running.
        guard scan > appliedScan else { return }
        appliedScan = scan

        var grouped: [String: [ServerWindow]] = [:]
        for window in scanned {
            grouped[window.bundleIdentifier, default: []].append(window)
        }
        byBundleIdentifier = grouped

        // Equality short-circuit: space changes and app activations fire
        // constantly and usually leave the window set untouched. Republishing
        // an identical array would invalidate every consumer for nothing.
        guard scanned != windows else { return }
        windows = scanned
        generation &+= 1
    }

    /// Pure, off-main scan. Takes the owner map rather than reading any
    /// shared state so it is safe on the scan queue and exercisable directly.
    static func scan(owners: [pid_t: String]) -> [ServerWindow] {
        let connection = CGSMainConnectionID()

        // Deliberately the "all windows" variant. The on-screen-only option
        // is an order of magnitude cheaper but excludes precisely what this
        // index exists to find.
        let entries = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []

        var result: [ServerWindow] = []
        result.reserveCapacity(entries.count / 4)

        for entry in entries {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bundleIdentifier = owners[pid],
                  bundleIdentifier != Self.dockyBundleIdentifier,
                  !excludedBundleIdentifiers.contains(bundleIdentifier),
                  let number = entry[kCGWindowNumber as String] as? NSNumber else {
                continue
            }

            // Layer 0 is the ordinary application-window layer; anything else
            // is a panel, overlay or system surface.
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  ((entry[kCGWindowAlpha as String] as? Double) ?? 0) > 0 else {
                continue
            }

            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= minimumSize.width,
                  frame.height >= minimumSize.height else {
                continue
            }

            let windowID = CGWindowID(number.uint32Value)

            // Space membership doubles as the liveness test. CGWindowList
            // keeps serving entries for windows that have already closed --
            // 18 of them on the machine this was written on -- and those are
            // exactly the entries the WindowServer places on no space. Using
            // this rather than `SLSWindowIsOrderedIn` matters, because
            // ordered-out is also true of minimized windows, which are alive
            // and which this index must keep.
            let spaces = Set(SLSSpacesForWindow(windowID, connection: connection))
            guard !spaces.isEmpty else { continue }

            let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }

            result.append(ServerWindow(
                cgWindowID: windowID,
                processIdentifier: pid,
                bundleIdentifier: bundleIdentifier,
                title: title,
                frame: frame,
                isMinimized: !SLSWindowIsOrderedIn(connection, windowID),
                spaces: spaces
            ))
        }

        return result
    }

    private static let dockyBundleIdentifier =
        Bundle.main.bundleIdentifier ?? "gt.quintero.Docky"
}
