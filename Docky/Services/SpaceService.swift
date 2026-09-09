//
//  SpaceService.swift
//  Docky
//
//  Answers "which Mission Control space is this?" and "which space is that
//  window on?" — neither of which macOS exposes publicly. Wraps the SkyLight
//  space SPI in `Docky/Private/CGSPrivate.swift` so the rest of the app never
//  handles raw space ids or CoreFoundation bridging.
//
//  Nothing in Docky's UI consumes this yet. It exists so that per-space
//  behavior can be built on a single, testable notion of space membership
//  rather than each feature re-deriving one from CGWindowList scans.
//
//  Main-thread by convention, matching `WindowRegistry`: every call here is a
//  synchronous WindowServer round trip measured in tens of microseconds, and
//  the callers that will use it (dock rebuilds, click decisions) are already
//  on main. Hopping to an actor would add latency to a click for no benefit.
//

import AppKit
import Combine
import Foundation

final class SpaceService: ObservableObject {
    static let shared = SpaceService()

    /// The space topology: which spaces exist and which one each display is
    /// showing. Changes rarely — a new desktop, a display plugged in.
    @Published private(set) var snapshot: SpaceSnapshot = .unavailable

    /// Which windows are on which spaces. Changes constantly, which is why it
    /// is published separately from the topology.
    @Published private(set) var membership: SpaceMembership = .empty

    /// False when the private space APIs could not be resolved. Every query
    /// below then degrades to space-unaware answers.
    var isAvailable: Bool {
        snapshot.isAvailable
    }

    /// Supplies the windows worth classifying. Injected rather than read from
    /// `WindowRegistry` so this service has no dependency on it: the registry
    /// already owns the hard problem of deciding what counts as a real window
    /// (AX policy, size floors, per-app quirks, Docky's own exclusion), and
    /// classifying only what it already tracks inherits all of that. Building
    /// a parallel window list here would, among other things, pull in Finder's
    /// desktop window.
    private var knownWindowIDs: () -> Set<CGWindowID> = { [] }

    private let connection = CGSMainConnectionID()
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var isStarted = false
    private var lastRefreshAt: Date?

    /// Last non-empty answer per window, so a window that becomes
    /// unclassifiable keeps its space instead of appearing to belong nowhere.
    /// Never cleared by an empty answer — only by the window going away.
    private var lastKnownSpaces: [CGWindowID: Set<CGSSpaceID>] = [:]

    /// Per-window classification is ~40µs, so a burst of stragglers is cheap
    /// but not free. Beyond this many in one pass we stop and serve the rest
    /// from cache rather than stalling a space switch.
    private static let stragglerLimit = 64

    /// Coalesces the bursts of refresh requests that a single user action can
    /// produce (a space switch also moves the menu bar and can reconfigure
    /// displays).
    private static let minimumRefreshInterval: TimeInterval = 0.05

    private init() {}

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Begins tracking. `windowIDs` is consulted on every membership refresh;
    /// pass a closure over whatever window set the caller considers real.
    func start(windowIDs: @escaping () -> Set<CGWindowID>) {
        knownWindowIDs = windowIDs
        guard !isStarted else {
            refresh(force: true)
            return
        }
        isStarted = true
        subscribe()
        refresh(force: true)
    }

    private func subscribe() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Handled synchronously and in full: a stale active space is the
            // one error the consumers cannot paper over.
            self?.refresh(force: true)
        })

        // Waking can invalidate both the topology and every window's mapping.
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(force: true)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(force: true)
        })
    }

    // MARK: - Refreshing

    /// Recomputes topology and membership. Rate-limited unless `force`.
    func refresh(force: Bool = false) {
        if !force, let lastRefreshAt,
           Date().timeIntervalSince(lastRefreshAt) < Self.minimumRefreshInterval {
            return
        }
        lastRefreshAt = Date()

        guard cgsSpacesAvailable else {
            publish(snapshot: .unavailable, membership: .empty)
            return
        }

        generation &+= 1
        let nextSnapshot = makeSnapshot(generation: generation)
        let nextMembership = makeMembership(snapshot: nextSnapshot, generation: generation)
        publish(snapshot: nextSnapshot, membership: nextMembership)
    }

    /// Recomputes only which windows are on which spaces, leaving the
    /// topology alone. This is the common case: windows open and close far
    /// more often than desktops are created.
    func refreshMembership() {
        guard snapshot.isAvailable else { return }
        generation &+= 1
        publish(
            snapshot: snapshot,
            membership: makeMembership(snapshot: snapshot, generation: generation)
        )
    }

    /// Assigning both under one guard keeps observers from ever seeing a
    /// topology and a membership that disagree. Equality short-circuits
    /// matter: `activeSpaceDidChange` also fires for events that leave the
    /// space unchanged, and republishing an identical value would redraw
    /// every dock tile for nothing.
    private func publish(snapshot nextSnapshot: SpaceSnapshot, membership nextMembership: SpaceMembership) {
        if !equalIgnoringGeneration(snapshot, nextSnapshot) {
            snapshot = nextSnapshot
        }
        if !equalIgnoringGeneration(membership, nextMembership) {
            membership = nextMembership
        }
    }

    private func equalIgnoringGeneration(_ lhs: SpaceSnapshot, _ rhs: SpaceSnapshot) -> Bool {
        lhs.isAvailable == rhs.isAvailable
            && lhs.displays == rhs.displays
            && lhs.activeSpaceByDisplay == rhs.activeSpaceByDisplay
            && lhs.focusedDisplayIdentifier == rhs.focusedDisplayIdentifier
    }

    private func equalIgnoringGeneration(_ lhs: SpaceMembership, _ rhs: SpaceMembership) -> Bool {
        lhs.spacesByWindow == rhs.spacesByWindow
            && lhs.windowsBySpace == rhs.windowsBySpace
            && lhs.staleWindowIDs == rhs.staleWindowIDs
    }

    private func makeSnapshot(generation: UInt64) -> SpaceSnapshot {
        let displays = Self.parseManagedDisplaySpaces(CGSManagedDisplaySpaces(connection: connection))
        guard !displays.isEmpty else {
            // The topology is unreadable but the active space may not be.
            // A single-display view is a better answer than none.
            guard let activeID = SLSActiveSpace(connection: connection) else {
                return .unavailable
            }
            let fallbackDisplay = SLSDisplayIdentifier(forSpace: activeID, connection: connection) ?? "Main"
            let space = SpaceIdentity(
                id: activeID,
                uuid: nil,
                displayIdentifier: fallbackDisplay,
                kind: SpaceKind(rawType: SLSSpaceType(of: activeID, connection: connection) ?? CGSSpaceType.user),
                ordinal: nil
            )
            return SpaceSnapshot(
                generation: generation,
                isAvailable: true,
                displays: [DisplaySpaces(displayIdentifier: fallbackDisplay, spaces: [space], currentSpace: space)],
                activeSpaceByDisplay: [fallbackDisplay: space],
                focusedDisplayIdentifier: fallbackDisplay
            )
        }

        // Prefer the live per-display query over the `Current Space` key: the
        // topology array is a point-in-time snapshot and can lag a swipe.
        var resolved: [DisplaySpaces] = []
        var activeByDisplay: [String: SpaceIdentity] = [:]
        for display in displays {
            let liveID = SLSCurrentSpace(forDisplay: display.displayIdentifier, connection: connection)
            let current = liveID.flatMap { id in display.spaces.first { $0.id == id } } ?? display.currentSpace
            resolved.append(DisplaySpaces(
                displayIdentifier: display.displayIdentifier,
                spaces: display.spaces,
                currentSpace: current
            ))
            if let current {
                activeByDisplay[display.displayIdentifier] = current
            }
        }

        let focused = SLSActiveMenuBarDisplayIdentifier(connection: connection)
            ?? SLSActiveSpace(connection: connection)
                .flatMap { SLSDisplayIdentifier(forSpace: $0, connection: connection) }

        return SpaceSnapshot(
            generation: generation,
            isAvailable: true,
            displays: resolved,
            activeSpaceByDisplay: activeByDisplay,
            focusedDisplayIdentifier: focused
        )
    }

    private func makeMembership(snapshot: SpaceSnapshot, generation: UInt64) -> SpaceMembership {
        let known = knownWindowIDs()
        guard !known.isEmpty else {
            return SpaceMembership(generation: generation, spacesByWindow: [:], windowsBySpace: [:], staleWindowIDs: [])
        }

        // One call per space rather than one per window: a five-space sweep
        // costs about 0.15ms, against ~1.3ms to ask about thirty windows
        // individually.
        var sweep: [CGSSpaceID: [CGWindowID]] = [:]
        for space in snapshot.allSpaces {
            sweep[space.id] = SLSWindowIDs(onSpace: space.id, connection: connection)
        }

        let result = Self.resolveMembership(
            sweep: sweep,
            knownWindowIDs: known,
            lastKnownSpaces: lastKnownSpaces,
            stragglerLimit: Self.stragglerLimit,
            generation: generation,
            classify: { [connection] windowID in
                Set(SLSSpacesForWindow(windowID, connection: connection))
            }
        )

        // Remember every live answer, and forget windows that no longer exist
        // so a recycled CGWindowID can't inherit a dead window's space.
        lastKnownSpaces = lastKnownSpaces.filter { known.contains($0.key) }
        for (windowID, spaces) in result.spacesByWindow where !spaces.isEmpty {
            if !result.staleWindowIDs.contains(windowID) {
                lastKnownSpaces[windowID] = spaces
            }
        }

        return result
    }

    // MARK: - Pure classification

    /// Parses the WindowServer's per-display topology payload.
    ///
    /// Separated out and left free of side effects because this is where the
    /// payload's quirks live — empty UUIDs, a `"Main"` display identifier when
    /// displays share spaces, missing keys on older systems — and those are
    /// worth being able to exercise against a recorded payload.
    static func parseManagedDisplaySpaces(_ payload: [[String: Any]]) -> [DisplaySpaces] {
        payload.compactMap { entry in
            guard let displayIdentifier = entry["Display Identifier"] as? String else { return nil }

            let rawSpaces = entry["Spaces"] as? [[String: Any]] ?? []
            let spaces = rawSpaces.enumerated().compactMap { index, raw in
                parseSpace(raw, displayIdentifier: displayIdentifier, ordinal: index + 1)
            }

            let currentID = (entry["Current Space"] as? [String: Any])
                .flatMap { ($0["id64"] as? NSNumber)?.uint64Value }
            let current = currentID.flatMap { id in spaces.first { $0.id == id } }

            return DisplaySpaces(
                displayIdentifier: displayIdentifier,
                spaces: spaces,
                currentSpace: current
            )
        }
    }

    private static func parseSpace(
        _ raw: [String: Any],
        displayIdentifier: String?,
        ordinal: Int?
    ) -> SpaceIdentity? {
        guard let id = (raw["id64"] as? NSNumber)?.uint64Value else { return nil }
        // An empty uuid is a real value the WindowServer reports, not a
        // missing one; it must not be mistaken for an identity.
        let uuid = (raw["uuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let type = (raw["type"] as? NSNumber)?.int32Value ?? CGSSpaceType.user

        return SpaceIdentity(
            id: id,
            uuid: uuid,
            displayIdentifier: displayIdentifier,
            kind: SpaceKind(rawType: type),
            ordinal: ordinal
        )
    }

    /// Combines a per-space sweep, per-window fallbacks and the last-known
    /// cache into one membership table.
    ///
    /// The sweep is fast but slightly lossy — it has been observed to omit a
    /// real application window that per-window classification placed
    /// correctly — so anything it misses gets asked about individually, and
    /// only then falls back to cache.
    static func resolveMembership(
        sweep: [CGSSpaceID: [CGWindowID]],
        knownWindowIDs: Set<CGWindowID>,
        lastKnownSpaces: [CGWindowID: Set<CGSSpaceID>],
        stragglerLimit: Int,
        generation: UInt64,
        classify: (CGWindowID) -> Set<CGSSpaceID>
    ) -> SpaceMembership {
        var spacesByWindow: [CGWindowID: Set<CGSSpaceID>] = [:]

        // Intersecting with the known set is what keeps desktop pictures,
        // menu-bar strips and every other WindowServer-owned surface out.
        for (space, windows) in sweep {
            for windowID in windows where knownWindowIDs.contains(windowID) {
                spacesByWindow[windowID, default: []].insert(space)
            }
        }

        var stale: Set<CGWindowID> = []
        let missing = knownWindowIDs.subtracting(spacesByWindow.keys).sorted()
        for (index, windowID) in missing.enumerated() {
            if index < stragglerLimit {
                let spaces = classify(windowID)
                if !spaces.isEmpty {
                    spacesByWindow[windowID] = spaces
                    continue
                }
            }
            if let remembered = lastKnownSpaces[windowID], !remembered.isEmpty {
                spacesByWindow[windowID] = remembered
                stale.insert(windowID)
            }
            // Otherwise the window genuinely has no space — a helper window
            // that was created but never mapped. Absent from the table.
        }

        var windowsBySpace: [CGSSpaceID: Set<CGWindowID>] = [:]
        for (windowID, spaces) in spacesByWindow {
            for space in spaces {
                windowsBySpace[space, default: []].insert(windowID)
            }
        }

        return SpaceMembership(
            generation: generation,
            spacesByWindow: spacesByWindow,
            windowsBySpace: windowsBySpace,
            staleWindowIDs: stale
        )
    }

    // MARK: - Queries
    //
    // Every query fails open: with spaces unavailable, "is this here?" is yes
    // and filters return their input untouched, so behavior collapses exactly
    // onto what Docky did before it understood spaces. The one exception is
    // `hasWindowsElsewhere`, which fails closed — claiming a window exists on
    // another space when we cannot see one would let a caller act on a guess.

    func spaces(of windowID: CGWindowID?) -> Set<SpaceIdentity> {
        guard let windowID, isAvailable else { return [] }
        let ids = membership.spaces(of: windowID)
        let all = snapshot.allSpaces
        return Set(all.filter { ids.contains($0.id) })
    }

    func isOnActiveSpace(_ windowID: CGWindowID?, onDisplay displayIdentifier: String? = nil) -> Bool {
        guard isAvailable, let active = snapshot.activeSpace(onDisplay: displayIdentifier) else { return true }
        guard let windowID else { return true }
        let spaces = membership.spaces(of: windowID)
        guard !spaces.isEmpty else { return true }
        return spaces.contains(active.id)
    }

    /// A window resident on every space — "Assign to All Desktops".
    func isSticky(_ windowID: CGWindowID?) -> Bool {
        guard isAvailable, let windowID else { return false }
        let spaces = membership.spaces(of: windowID)
        let userSpaces = snapshot.allSpaces.filter { $0.kind.isUserDesktop }
        guard userSpaces.count > 1 else { return false }
        return userSpaces.allSatisfy { spaces.contains($0.id) }
    }

    func windowIDs(on space: SpaceIdentity) -> Set<CGWindowID> {
        membership.windowsBySpace[space.id] ?? []
    }

    func windows<W: SpaceScopedWindowRef>(_ windows: [W], on space: SpaceIdentity) -> [W] {
        guard isAvailable else { return windows }
        return windows.filter { window in
            guard let windowID = window.cgWindowID else { return true }
            let spaces = membership.spaces(of: windowID)
            // A window we cannot place is shown rather than hidden: a
            // classification miss must never make an app disappear.
            guard !spaces.isEmpty else { return true }
            return spaces.contains(space.id)
        }
    }

    func windows<W: SpaceScopedWindowRef>(
        _ windows: [W],
        of bundleIdentifier: String,
        on space: SpaceIdentity
    ) -> [W] {
        self.windows(windows.filter { $0.bundleIdentifier == bundleIdentifier }, on: space)
    }

    func minimizedWindows<W: SpaceScopedWindowRef>(
        _ windows: [W],
        of bundleIdentifier: String,
        on space: SpaceIdentity
    ) -> [W] {
        self.windows(windows.filter { $0.bundleIdentifier == bundleIdentifier && $0.isMinimized }, on: space)
    }

    func hasWindows<W: SpaceScopedWindowRef>(
        _ windows: [W],
        of bundleIdentifier: String,
        on space: SpaceIdentity
    ) -> Bool {
        !self.windows(windows, of: bundleIdentifier, on: space).isEmpty
    }

    /// Whether the app has a window on some space other than `space`.
    ///
    /// Fails closed: unavailable spaces, or windows we cannot classify, report
    /// `false`. A caller deciding between "switch to that space" and "open a
    /// window here" must not act on a window it only suspects exists.
    func hasWindowsElsewhere<W: SpaceScopedWindowRef>(
        _ windows: [W],
        of bundleIdentifier: String,
        excluding space: SpaceIdentity
    ) -> Bool {
        guard isAvailable else { return false }
        return windows.contains { window in
            guard window.bundleIdentifier == bundleIdentifier,
                  let windowID = window.cgWindowID else {
                return false
            }
            let spaces = membership.spaces(of: windowID)
            guard !spaces.isEmpty else { return false }
            return !spaces.contains(space.id)
        }
    }
}
