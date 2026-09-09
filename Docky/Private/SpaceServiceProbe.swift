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
    static func dumpState() {
        print("=== SpaceService probe ===")
        print("timestamp: \(Date())")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        dumpSymbols()

        guard cgsSpacesAvailable else {
            print("\nSpace APIs unavailable — SpaceService will report isAvailable == false")
            print("and every query falls back to space-unaware behavior.")
            print("===")
            return
        }

        let connection = CGSMainConnectionID()
        dumpTopology(connection: connection)
        dumpActiveSpaceAgreement(connection: connection)
        dumpSpaceTypes(connection: connection)

        let service = startedService()
        dumpWindows(service: service, connection: connection)
        dumpSweepVersusPerWindow(service: service, connection: connection)
        dumpTiming(service: service)

        print("===")
    }

    // MARK: Sections

    private static func dumpSymbols() {
        print("\n--- symbol resolution ---")
        for entry in cgsSpaceSymbolReport() {
            print("  \(entry.resolved ? "ok  " : "MISS") \(entry.name)")
        }
    }

    private static func dumpTopology(connection: CGSConnectionID) {
        let payload = CGSManagedDisplaySpaces(connection: connection)
        print("\n--- raw CGSCopyManagedDisplaySpaces payload ---")
        print("  displays: \(payload.count)")
        for entry in payload {
            print("  \(entry)")
        }

        print("\n--- parsed topology ---")
        let displays = SpaceService.parseManagedDisplaySpaces(payload)
        if displays.isEmpty, !payload.isEmpty {
            print("  PARSE FAILED — payload is non-empty but produced no displays.")
            print("  The payload keys have probably changed on this OS.")
        }
        for display in displays {
            print("  display \(display.displayIdentifier): \(display.spaces.count) space(s)")
            for space in display.spaces {
                let marker = space.id == display.currentSpace?.id ? " <- current" : ""
                print("    #\(space.ordinal.map(String.init) ?? "?") id=\(space.id) "
                    + "uuid=\(space.uuid ?? "<empty>") kind=\(space.kind)\(marker)")
            }
        }
    }

    /// Three independent ways to ask "which space is active". They should
    /// agree; a disagreement means one of them has changed meaning and
    /// `SpaceService.makeSnapshot` is picking the wrong one.
    private static func dumpActiveSpaceAgreement(connection: CGSConnectionID) {
        print("\n--- active space agreement ---")
        let payload = CGSManagedDisplaySpaces(connection: connection)
        let displays = SpaceService.parseManagedDisplaySpaces(payload)

        for display in displays {
            let fromPayload = display.currentSpace?.id
            let fromLiveQuery = SLSCurrentSpace(forDisplay: display.displayIdentifier, connection: connection)
            print("  \(display.displayIdentifier): payload=\(describe(fromPayload)) live=\(describe(fromLiveQuery))"
                + (fromPayload == fromLiveQuery ? "" : "  MISMATCH"))
        }

        let global = SLSActiveSpace(connection: connection)
        let focusedDisplay = SLSActiveMenuBarDisplayIdentifier(connection: connection)
        print("  SLSGetActiveSpace: \(describe(global))")
        print("  menu-bar display: \(focusedDisplay ?? "<unknown>")")
        if let focusedDisplay,
           let focused = displays.first(where: { $0.displayIdentifier == focusedDisplay })?.currentSpace?.id,
           let global, focused != global {
            print("  MISMATCH — focused display's current space (\(focused)) != SLSGetActiveSpace (\(global))")
        }
    }

    /// Re-checks the "unknown space" sentinel. `SLSSpaceGetType` returns 3 for
    /// an id that does not exist and 0 for an ordinary desktop, so "non-zero
    /// means fullscreen" is wrong — worth re-verifying per OS before anyone
    /// relies on the type value.
    private static func dumpSpaceTypes(connection: CGSConnectionID) {
        print("\n--- space types ---")
        let displays = SpaceService.parseManagedDisplaySpaces(CGSManagedDisplaySpaces(connection: connection))
        for space in displays.flatMap(\.spaces) {
            let type = SLSSpaceType(of: space.id, connection: connection)
            print("  id=\(space.id) type=\(describe(type.map(Int.init)))")
        }
        let bogus: CGSSpaceID = 0xDEAD_BEEF
        let bogusType = SLSSpaceType(of: bogus, connection: connection)
        print("  id=\(bogus) (nonexistent) type=\(describe(bogusType.map(Int.init)))"
            + (bogusType == CGSSpaceType.invalid ? "  (expected \(CGSSpaceType.invalid))" : "  UNEXPECTED"))
    }

    /// The acceptance criterion for minimized windows, checkable at a glance:
    /// every minimized window should still report a space even though
    /// `SLSWindowIsOrderedIn` is false for it.
    private static func dumpWindows(service: SpaceService, connection: CGSConnectionID) {
        print("\n--- windows ---")
        let windows = WindowRegistry.shared.windows
        print("  registry windows: \(windows.count), classified: \(service.membership.spacesByWindow.count)")

        var unclassifiedMinimized = 0
        for window in windows {
            guard let windowID = window.cgWindowID else {
                print("  \(window.bundleIdentifier): no cgWindowID — unclassifiable, will be treated as present")
                continue
            }
            let spaces = service.membership.spaces(of: windowID)
            let stale = service.membership.staleWindowIDs.contains(windowID) ? " STALE" : ""
            let orderedIn = SLSWindowIsOrderedIn(connection, windowID)
            print("  wid=\(windowID) min=\(window.isMinimized) orderedIn=\(orderedIn) "
                + "spaces=\(spaces.sorted())\(stale)  \(window.bundleIdentifier) — \(window.windowTitle)")
            if window.isMinimized, spaces.isEmpty {
                unclassifiedMinimized += 1
            }
        }

        if unclassifiedMinimized > 0 {
            print("  FAILURE: \(unclassifiedMinimized) minimized window(s) have no space.")
            print("  Per-space minimized windows depend on this; check CGSWindowListOptions.includeOrderedOut.")
        } else {
            print("  ok — every minimized window kept a space")
        }
    }

    /// The per-space sweep is the fast path but has been seen to omit real
    /// windows, which is why `resolveMembership` follows it with per-window
    /// calls. This prints exactly what the sweep lost, so the size of that
    /// problem is visible on each OS rather than assumed.
    private static func dumpSweepVersusPerWindow(service: SpaceService, connection: CGSConnectionID) {
        print("\n--- sweep vs per-window ---")
        let known = Set(WindowRegistry.shared.windows.compactMap(\.cgWindowID))
        guard !known.isEmpty else {
            print("  no windows to compare")
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
            print("  wid=\(windowID) sweep=\(sweep.sorted()) perWindow=\(direct.sorted())")
        }
        print(mismatches == 0
            ? "  ok — sweep and per-window agree on all \(known.count) window(s)"
            : "  \(mismatches) disagreement(s); the straggler pass covers these")
    }

    private static func dumpTiming(service: SpaceService) {
        print("\n--- timing ---")
        let start = DispatchTime.now().uptimeNanoseconds
        service.refresh(force: true)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print(String(format: "  full refresh: %.3f ms (%d space(s), %d window(s))",
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
