//
//  SpaceServiceProbe.swift
//  Docky
//
//  Diagnostics for the SkyLight space SPI behind `SpaceService`.
//
//  None of what makes that SPI risky is expressible as a unit test: whether a
//  future macOS still exports these symbols, still spells the topology payload
//  the same way, still reports a minimized window's space, and still returns
//  the same sentinel for an unknown space are all questions only a real
//  WindowServer can answer. This probe asks them all in one pass and prints
//  the answers, so verifying Docky on a new OS is running one menu item and
//  reading the output rather than re-deriving the API by hand.
//
//  Invoke from the debug status menu ("Space Service Probe…") or from lldb:
//      (lldb) expr SpaceServiceProbe.dumpState()
//

#if DEBUG

import AppKit
import Foundation

enum SpaceServiceProbe {
    /// Collected output, also written to a file. `print` alone is not enough:
    /// launching the app with `open` detaches stdout, so a probe that only
    /// printed would look like it did nothing.
    private static var transcript: [String] = []

    private static func emit(_ line: String) {
        transcript.append(line)
        print(line)
    }

    static func dumpState() {
        transcript = []
        emit("=== SpaceService probe ===")
        emit("timestamp: \(Date())")
        emit("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        dumpSymbols()

        guard cgsSpacesAvailable else {
            emit("\nSpace APIs unavailable — SpaceService will report isAvailable == false")
            emit("and every query falls back to space-unaware behavior.")
            emit("===")
            return
        }

        let connection = CGSMainConnectionID()
        dumpTopology(connection: connection)
        dumpActiveSpaceAgreement(connection: connection)
        dumpSpaceTypes(connection: connection)

        let service = startedService()
        dumpWindows(service: service, connection: connection)
        dumpRegistryBlindSpot(service: service, connection: connection)
        dumpSweepVersusPerWindow(service: service, connection: connection)
        dumpTiming(service: service)

        emit("===")
        writeTranscript()
    }

    /// Does Docky's window model actually contain windows on other spaces?
    ///
    /// Everything space-scoped is filtered *down* from `WindowRegistry`, which
    /// is built from Accessibility, and AX does not reliably report windows on
    /// other spaces. If the registry never sees them, then scoping a list to
    /// the current space is a no-op — the list was already current-space-only —
    /// and, worse, any "all spaces" affordance is a promise that cannot be kept.
    ///
    /// Compares the registry against the WindowServer's own answer: real,
    /// ordered-in, layer-0 windows that live on a space other than the active
    /// one.
    private static func dumpRegistryBlindSpot(service: SpaceService, connection: CGSConnectionID) {
        emit("\n--- registry vs WindowServer (the 'All Spaces' question) ---")
        guard let active = service.snapshot.activeSpace else {
            emit("  no active space; skipping")
            return
        }

        let registryIDs = Set(WindowRegistry.shared.windows.compactMap(\.cgWindowID))
        let entries = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] ?? []

        var elsewhereTotal = 0
        var elsewhereMissing: [(CGWindowID, String)] = []
        for entry in entries {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            let windowID = CGWindowID(number.uint32Value)

            var bounds = CGRect.zero
            if let dict = entry[kCGWindowBounds as String] as? NSDictionary,
               let parsed = CGRect(dictionaryRepresentation: dict) {
                bounds = parsed
            }
            guard bounds.width >= 200, bounds.height >= 200 else { continue }
            // Ordered-in filters the stale entries CGWindowList keeps serving
            // for windows that have already closed.
            guard SLSWindowIsOrderedIn(connection, windowID) else { continue }

            let spaces = Set(SLSSpacesForWindow(windowID, connection: connection))
            guard !spaces.isEmpty, !spaces.contains(active.id) else { continue }

            elsewhereTotal += 1
            if !registryIDs.contains(windowID) {
                let owner = (entry[kCGWindowOwnerName as String] as? String) ?? "?"
                elsewhereMissing.append((windowID, owner))
            }
        }

        emit("  live windows on other spaces (per WindowServer): \(elsewhereTotal)")
        emit("  of those, missing from WindowRegistry:            \(elsewhereMissing.count)")
        for (windowID, owner) in elsewhereMissing.prefix(20) {
            emit("    wid=\(windowID) \(owner)")
        }

        if elsewhereTotal == 0 {
            emit("  INCONCLUSIVE — nothing is open on another space. Put a window")
            emit("  on another desktop, come back here, and re-run.")
        } else if elsewhereMissing.count == elsewhereTotal {
            emit("  CONFIRMED BLIND: the registry sees none of them. Scoping the")
            emit("  switcher to the current space is therefore a no-op, and an")
            emit("  'All Spaces' option cannot list what it claims to.")
        } else if elsewhereMissing.isEmpty {
            emit("  registry sees all of them — space scoping is meaningful as built.")
        } else {
            emit("  PARTIAL: the registry sees some off-space windows but not all,")
            emit("  so scoping works for some apps and silently not for others.")
        }
    }

    /// Writes the transcript next to the app's container so it survives being
    /// launched with `open`, which detaches stdout.
    private static func writeTranscript() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("docky-space-probe.txt")
        do {
            try transcript.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            // NSLog rather than print: this line has to be findable in Console
            // even when stdout went nowhere.
            NSLog("[Docky] Space probe written to %@", url.path)
            print("\nwritten to: \(url.path)")
        } catch {
            NSLog("[Docky] Space probe could not write transcript: %@", error.localizedDescription)
        }
    }

    // MARK: Sections

    private static func dumpSymbols() {
        emit("\n--- symbol resolution ---")
        for entry in cgsSpaceSymbolReport() {
            emit("  \(entry.resolved ? "ok  " : "MISS") \(entry.name)")
        }
    }

    private static func dumpTopology(connection: CGSConnectionID) {
        let payload = CGSManagedDisplaySpaces(connection: connection)
        emit("\n--- raw CGSCopyManagedDisplaySpaces payload ---")
        emit("  displays: \(payload.count)")
        for entry in payload {
            emit("  \(entry)")
        }

        emit("\n--- parsed topology ---")
        let displays = SpaceService.parseManagedDisplaySpaces(payload)
        if displays.isEmpty, !payload.isEmpty {
            emit("  PARSE FAILED — payload is non-empty but produced no displays.")
            emit("  The payload keys have probably changed on this OS.")
        }
        for display in displays {
            emit("  display \(display.displayIdentifier): \(display.spaces.count) space(s)")
            for space in display.spaces {
                let marker = space.id == display.currentSpace?.id ? " <- current" : ""
                emit("    #\(space.ordinal.map(String.init) ?? "?") id=\(space.id) "
                    + "uuid=\(space.uuid ?? "<empty>") kind=\(space.kind)\(marker)")
            }
        }
    }

    /// Three independent ways to ask "which space is active". They should
    /// agree; a disagreement means one of them has changed meaning and
    /// `SpaceService.makeSnapshot` is picking the wrong one.
    private static func dumpActiveSpaceAgreement(connection: CGSConnectionID) {
        emit("\n--- active space agreement ---")
        let payload = CGSManagedDisplaySpaces(connection: connection)
        let displays = SpaceService.parseManagedDisplaySpaces(payload)

        for display in displays {
            let fromPayload = display.currentSpace?.id
            let fromLiveQuery = SLSCurrentSpace(forDisplay: display.displayIdentifier, connection: connection)
            emit("  \(display.displayIdentifier): payload=\(describe(fromPayload)) live=\(describe(fromLiveQuery))"
                + (fromPayload == fromLiveQuery ? "" : "  MISMATCH"))
        }

        let global = SLSActiveSpace(connection: connection)
        let focusedDisplay = SLSActiveMenuBarDisplayIdentifier(connection: connection)
        emit("  SLSGetActiveSpace: \(describe(global))")
        emit("  menu-bar display: \(focusedDisplay ?? "<unknown>")")
        if let focusedDisplay,
           let focused = displays.first(where: { $0.displayIdentifier == focusedDisplay })?.currentSpace?.id,
           let global, focused != global {
            emit("  MISMATCH — focused display's current space (\(focused)) != SLSGetActiveSpace (\(global))")
        }
    }

    /// Re-checks the "unknown space" sentinel. `SLSSpaceGetType` returns 3 for
    /// an id that does not exist and 0 for an ordinary desktop, so "non-zero
    /// means fullscreen" is wrong — worth re-verifying per OS before anyone
    /// relies on the type value.
    private static func dumpSpaceTypes(connection: CGSConnectionID) {
        emit("\n--- space types ---")
        let displays = SpaceService.parseManagedDisplaySpaces(CGSManagedDisplaySpaces(connection: connection))
        for space in displays.flatMap(\.spaces) {
            let type = SLSSpaceType(of: space.id, connection: connection)
            emit("  id=\(space.id) type=\(describe(type.map(Int.init)))")
        }
        let bogus: CGSSpaceID = 0xDEAD_BEEF
        let bogusType = SLSSpaceType(of: bogus, connection: connection)
        emit("  id=\(bogus) (nonexistent) type=\(describe(bogusType.map(Int.init)))"
            + (bogusType == CGSSpaceType.invalid ? "  (expected \(CGSSpaceType.invalid))" : "  UNEXPECTED"))
    }

    /// The acceptance criterion for minimized windows, checkable at a glance:
    /// every minimized window should still report a space even though
    /// `SLSWindowIsOrderedIn` is false for it.
    private static func dumpWindows(service: SpaceService, connection: CGSConnectionID) {
        emit("\n--- windows ---")
        let windows = WindowRegistry.shared.windows
        emit("  registry windows: \(windows.count), classified: \(service.membership.spacesByWindow.count)")

        var unclassifiedMinimized = 0
        for window in windows {
            guard let windowID = window.cgWindowID else {
                emit("  \(window.bundleIdentifier): no cgWindowID — unclassifiable, will be treated as present")
                continue
            }
            let spaces = service.membership.spaces(of: windowID)
            let stale = service.membership.staleWindowIDs.contains(windowID) ? " STALE" : ""
            let orderedIn = SLSWindowIsOrderedIn(connection, windowID)
            emit("  wid=\(windowID) min=\(window.isMinimized) orderedIn=\(orderedIn) "
                + "spaces=\(spaces.sorted())\(stale)  \(window.bundleIdentifier) — \(window.windowTitle)")
            if window.isMinimized, spaces.isEmpty {
                unclassifiedMinimized += 1
            }
        }

        if unclassifiedMinimized > 0 {
            emit("  FAILURE: \(unclassifiedMinimized) minimized window(s) have no space.")
            emit("  Per-space minimized windows depend on this; check CGSWindowListOptions.includeOrderedOut.")
        } else {
            emit("  ok — every minimized window kept a space")
        }
    }

    /// The per-space sweep is the fast path but has been seen to omit real
    /// windows, which is why `resolveMembership` follows it with per-window
    /// calls. This prints exactly what the sweep lost, so the size of that
    /// problem is visible on each OS rather than assumed.
    private static func dumpSweepVersusPerWindow(service: SpaceService, connection: CGSConnectionID) {
        emit("\n--- sweep vs per-window ---")
        let known = Set(WindowRegistry.shared.windows.compactMap(\.cgWindowID))
        guard !known.isEmpty else {
            emit("  no windows to compare")
            return
        }

        var fromSweep: [CGWindowID: Set<CGSSpaceID>] = [:]
        for space in service.snapshot.allSpaces {
            for windowID in SLSWindowIDs(onSpace: space.id, connection: connection) where known.contains(windowID) {
                fromSweep[windowID, default: []].insert(space.id)
            }
        }

        var mismatches = 0
        for windowID in known.sorted() {
            let sweep = fromSweep[windowID] ?? []
            let direct = Set(SLSSpacesForWindow(windowID, connection: connection))
            guard sweep != direct else { continue }
            mismatches += 1
            emit("  wid=\(windowID) sweep=\(sweep.sorted()) perWindow=\(direct.sorted())")
        }
        emit(mismatches == 0
            ? "  ok — sweep and per-window agree on all \(known.count) window(s)"
            : "  \(mismatches) disagreement(s); the straggler pass covers these")
    }

    private static func dumpTiming(service: SpaceService) {
        emit("\n--- timing ---")
        let start = DispatchTime.now().uptimeNanoseconds
        service.refresh(force: true)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        emit(String(format: "  full refresh: %.3f ms (%d space(s), %d window(s))",
                     elapsed,
                     service.snapshot.allSpaces.count,
                     service.membership.spacesByWindow.count))
    }

    // MARK: Helpers

    /// The probe is the only consumer in this build, so it is also what starts
    /// the service. Idempotent — `start` refreshes when already running.
    private static func startedService() -> SpaceService {
        let service = SpaceService.shared
        service.start(windowIDs: { Set(WindowRegistry.shared.windows.compactMap(\.cgWindowID)) })
        return service
    }

    private static func describe(_ value: CGSSpaceID?) -> String {
        value.map(String.init) ?? "<none>"
    }

    private static func describe(_ value: Int?) -> String {
        value.map(String.init) ?? "<none>"
    }
}

#endif
