//
//  CGSPrivate.swift
//  Docky
//
//  SkyLight (CoreGraphics Services) SPI. Not for App Store submission without review.
//

import AppKit
import ApplicationServices
import CoreGraphics

typealias CGSConnectionID = Int
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

// Returns the system CGWindowID backing an AX window element. Preferred over
// the AXWindowNumber attribute, which some apps populate with their own
// internal IDs rather than the system window number.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
func CGSSetWindowBackgroundBlurRadius(
    _ connection: CGSConnectionID,
    _ windowID: Int,
    _ radius: Int
) -> Int32

// `CGWindowListCreateImage` follows the CoreFoundation Create Rule:
// the caller owns the returned reference (+1). Importing it via the
// public CoreGraphics header lets the clang `cf_returns_retained`
// audit balance ARC for us, but `@_silgen_name` bypasses that audit
// and Swift treats the return value as +0. The system still holds
// its +1, ARC emits an extra release at scope exit, and on Sequoia
// the freed slot gets reused fast enough that the next access
// SEGVs in `objc_release` (see the Sentry crash with
// `WorkspaceService.captureAppWindowPreview` at the top of the
// stack, with `rdi` holding a `Double`-shaped value reused from
// freed CGImage storage).
//
// Declaring the raw binding as `Unmanaged<CGImage>?` opts out of
// implicit ARC and lets us consume the +1 explicitly via
// `takeRetainedValue()` in the wrapper below. All five callers in
// `WorkspaceService.swift` keep working with a managed `CGImage?`.
@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImagePrivate(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> Unmanaged<CGImage>?

func CGWindowListCreateImagePrivate(
    _ screenBounds: CGRect,
    _ listOption: CGWindowListOption,
    _ windowID: CGWindowID,
    _ imageOption: CGWindowImageOption
) -> CGImage? {
    _CGWindowListCreateImagePrivate(
        screenBounds,
        listOption,
        windowID,
        imageOption
    )?.takeRetainedValue()
}

@_silgen_name("CGSGetWindowAlpha")
func CGSGetWindowAlpha(
    _ connection: CGSConnectionID,
    _ windowID: Int,
    _ alpha: UnsafeMutablePointer<Float>
) -> Int32

@_silgen_name("CGSSetWindowAlpha")
func CGSSetWindowAlpha(
    _ connection: CGSConnectionID,
    _ windowID: Int,
    _ alpha: Float
) -> Int32

// MARK: - SkyLight Process Switching (SLPS)

struct ProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

enum SLPSMode: UInt32 {
    case allWindows = 0x100
    case userGenerated = 0x200
    case noWindows = 0x400
}

private typealias SLPSSetFrontProcessWithOptionsType = @convention(c) (
    UnsafeMutableRawPointer,
    CGWindowID,
    UInt32
) -> CGError

private typealias SLPSPostEventRecordToType = @convention(c) (
    UnsafeMutableRawPointer,
    UnsafeMutablePointer<UInt8>
) -> CGError

private typealias SLSWindowIsOrderedInType = @convention(c) (
    CGSConnectionID,
    CGWindowID,
    UnsafeMutablePointer<Bool>
) -> CGError

// MARK: Spaces (see the "Spaces" section below for the wrappers)

private typealias SLSCopySpacesForWindowsType = @convention(c) (
    CGSConnectionID,
    Int32,
    CFArray
) -> Unmanaged<CFArray>?

private typealias SLSCopyWindowsWithOptionsAndTagsType = @convention(c) (
    CGSConnectionID,
    UInt32,
    CFArray,
    UInt32,
    UnsafeMutablePointer<UInt64>,
    UnsafeMutablePointer<UInt64>
) -> Unmanaged<CFArray>?

private typealias SLSCopyManagedDisplaySpacesType = @convention(c) (
    CGSConnectionID
) -> Unmanaged<CFArray>?

private typealias SLSManagedDisplayGetCurrentSpaceType = @convention(c) (
    CGSConnectionID,
    CFString
) -> CGSSpaceID

private typealias SLSGetActiveSpaceType = @convention(c) (CGSConnectionID) -> CGSSpaceID

private typealias SLSSpaceGetTypeType = @convention(c) (CGSConnectionID, CGSSpaceID) -> Int32

private typealias SLSCopyManagedDisplayForSpaceType = @convention(c) (
    CGSConnectionID,
    CGSSpaceID
) -> Unmanaged<CFString>?

private typealias SLSCopyActiveMenuBarDisplayIdentifierType = @convention(c) (
    CGSConnectionID
) -> Unmanaged<CFString>?

private var skyLightHandle: UnsafeMutableRawPointer?
private var setFrontProcessPtr: SLPSSetFrontProcessWithOptionsType?
private var postEventRecordPtr: SLPSPostEventRecordToType?
private var windowIsOrderedInPtr: SLSWindowIsOrderedInType?
private var copySpacesForWindowsPtr: SLSCopySpacesForWindowsType?
private var copyWindowsWithOptionsAndTagsPtr: SLSCopyWindowsWithOptionsAndTagsType?
private var copyManagedDisplaySpacesPtr: SLSCopyManagedDisplaySpacesType?
private var managedDisplayGetCurrentSpacePtr: SLSManagedDisplayGetCurrentSpaceType?
private var getActiveSpacePtr: SLSGetActiveSpaceType?
private var spaceGetTypePtr: SLSSpaceGetTypeType?
private var copyManagedDisplayForSpacePtr: SLSCopyManagedDisplayForSpaceType?
private var copyActiveMenuBarDisplayIdentifierPtr: SLSCopyActiveMenuBarDisplayIdentifierType?

/// Resolves the first of `names` that the framework exports. SkyLight vends
/// most of its API under both an `SLS*` and a legacy `CGS*` spelling; we ask
/// for `SLS*` first because that is the implementation's own name, and fall
/// back to the alias so a rename in either direction doesn't cost us the
/// symbol.
private func skyLightSymbol(
    _ handle: UnsafeMutableRawPointer,
    _ names: String...
) -> UnsafeMutableRawPointer? {
    for name in names {
        if let symbol = dlsym(handle, name) {
            return symbol
        }
    }
    return nil
}

// Single-threaded-by-convention: focus paths run on main, so the lazy load
// doesn't need a lock.
private func loadSkyLightFunctions() {
    guard skyLightHandle == nil else { return }

    let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(skyLightPath, RTLD_LAZY) else { return }
    skyLightHandle = handle

    if let symbol = dlsym(handle, "_SLPSSetFrontProcessWithOptions") {
        setFrontProcessPtr = unsafeBitCast(symbol, to: SLPSSetFrontProcessWithOptionsType.self)
    }
    if let symbol = dlsym(handle, "SLPSPostEventRecordTo") {
        postEventRecordPtr = unsafeBitCast(symbol, to: SLPSPostEventRecordToType.self)
    }
    if let symbol = dlsym(handle, "SLSWindowIsOrderedIn") {
        windowIsOrderedInPtr = unsafeBitCast(symbol, to: SLSWindowIsOrderedInType.self)
    }

    if let symbol = skyLightSymbol(handle, "SLSCopySpacesForWindows", "CGSCopySpacesForWindows") {
        copySpacesForWindowsPtr = unsafeBitCast(symbol, to: SLSCopySpacesForWindowsType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSCopyWindowsWithOptionsAndTags", "CGSCopyWindowsWithOptionsAndTags") {
        copyWindowsWithOptionsAndTagsPtr = unsafeBitCast(symbol, to: SLSCopyWindowsWithOptionsAndTagsType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces") {
        copyManagedDisplaySpacesPtr = unsafeBitCast(symbol, to: SLSCopyManagedDisplaySpacesType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace") {
        managedDisplayGetCurrentSpacePtr = unsafeBitCast(symbol, to: SLSManagedDisplayGetCurrentSpaceType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSGetActiveSpace", "CGSGetActiveSpace") {
        getActiveSpacePtr = unsafeBitCast(symbol, to: SLSGetActiveSpaceType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSSpaceGetType", "CGSSpaceGetType") {
        spaceGetTypePtr = unsafeBitCast(symbol, to: SLSSpaceGetTypeType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSCopyManagedDisplayForSpace", "CGSCopyManagedDisplayForSpace") {
        copyManagedDisplayForSpacePtr = unsafeBitCast(symbol, to: SLSCopyManagedDisplayForSpaceType.self)
    }
    if let symbol = skyLightSymbol(handle, "SLSCopyActiveMenuBarDisplayIdentifier", "CGSCopyActiveMenuBarDisplayIdentifier") {
        copyActiveMenuBarDisplayIdentifierPtr = unsafeBitCast(symbol, to: SLSCopyActiveMenuBarDisplayIdentifierType.self)
    }
}

// Whether the window server has the window mapped on some Space — the only
// signal that separates a live off-Space window from the stale entries
// CGWindowListCopyWindowInfo keeps serving after a window closes.
func SLSWindowIsOrderedIn(_ connection: CGSConnectionID, _ windowID: CGWindowID) -> Bool {
    loadSkyLightFunctions()
    guard let fn = windowIsOrderedInPtr else { return false }
    var orderedIn = false
    guard fn(connection, windowID, &orderedIn) == .success else { return false }
    return orderedIn
}

@discardableResult
func _SLPSSetFrontProcessWithOptions(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ wid: CGWindowID,
    _ mode: SLPSMode.RawValue
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = setFrontProcessPtr else { return CGError(rawValue: -1)! }
    return fn(psn, wid, mode)
}

@discardableResult
func SLPSPostEventRecordTo(
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>,
    _ bytes: UnsafeMutablePointer<UInt8>
) -> CGError {
    loadSkyLightFunctions()
    guard let fn = postEventRecordPtr else { return CGError(rawValue: -1)! }
    return fn(psn, bytes)
}

// MARK: - Spaces
//
// Mission Control spaces have no public API at all: neither "which space is
// this window on" nor "which space is the user looking at" is answerable
// through AppKit. AX is no help either — it cannot see windows on other
// spaces, which is why Docky currently has to infer "this app has a window
// somewhere else" from a CGWindowList scan.
//
// Every symbol below is resolved with dlsym rather than `@_silgen_name` on
// purpose. `@_silgen_name` emits a hard undefined symbol, so if a future
// macOS drops one of these the app fails to launch instead of losing one
// feature; and it bypasses clang's `cf_returns_retained` audit, which is the
// exact hazard documented above for `CGWindowListCreateImage`. Each `Copy`
// here follows the Create Rule (verified: CFGetRetainCount == 1 on the
// result), so the raw bindings return `Unmanaged` and the wrappers consume
// the +1 explicitly.
//
// Callers should go through `SpaceService`, not these functions.

/// Space selector mask for `SLSSpacesForWindows`.
///
/// Verified on macOS 15.7.9 by diffing results: `includesCurrent`,
/// `includesOthers` and `includesUser` each return an *empty* array on their
/// own — only the union is useful — and adding `visibleOnly` narrows the
/// result to the space currently on screen.
enum CGSSpaceSelector {
    static let includesCurrent: Int32 = 1 << 0
    static let includesOthers: Int32 = 1 << 1
    static let includesUser: Int32 = 1 << 2
    static let visibleOnly: Int32 = 1 << 16

    /// The only mask that reports a window's full space membership.
    static let all: Int32 = includesCurrent | includesOthers | includesUser
}

/// Window-list options for `SLSWindowIDs(onSpace:)`.
enum CGSWindowListOptions {
    /// Include windows the WindowServer has ordered out — which is what a
    /// minimized window is. **Required**: without this bit, minimized windows
    /// silently vanish from their space's window list (verified: a per-space
    /// sweep returned 24 windows without it and 27 with it, the difference
    /// being exactly the three minimized windows open at the time).
    static let includeOrderedOut: UInt32 = 1 << 0
    /// Include windows resident on every space rather than just one.
    static let includeSticky: UInt32 = 1 << 1

    static let all: UInt32 = includeOrderedOut | includeSticky | (1 << 2)
}

/// Space types as reported by `SLSSpaceType(of:)`.
enum CGSSpaceType {
    /// An ordinary user desktop.
    static let user: Int32 = 0
    /// What the WindowServer returns for a space ID that doesn't exist.
    /// Note this is *not* an ordering: do not treat "non-zero" as "fullscreen".
    static let invalid: Int32 = 3
}

/// Whether the space APIs resolved. When false every wrapper below returns an
/// empty/neutral result and callers must fall back to space-unaware behavior.
var cgsSpacesAvailable: Bool {
    loadSkyLightFunctions()
    return copySpacesForWindowsPtr != nil && copyManagedDisplaySpacesPtr != nil
}

/// The spaces a window is resident on. Empty when the window has never been
/// mapped onto a space (helper windows that were created but never shown), or
/// when the symbol is unavailable.
///
/// Reports minimized windows correctly — their space membership survives
/// being ordered out, which is what lets a minimized window stay attached to
/// the desktop it was minimized on.
func SLSSpacesForWindow(_ windowID: CGWindowID, connection: CGSConnectionID) -> [CGSSpaceID] {
    SLSSpacesForWindows([windowID], connection: connection)
}

/// The union of spaces the given windows are resident on.
///
/// Note this is a *union*, not a per-window answer: passing N window IDs
/// returns the deduplicated set of spaces they collectively occupy, so
/// per-window classification needs one call per window.
func SLSSpacesForWindows(_ windowIDs: [CGWindowID], connection: CGSConnectionID) -> [CGSSpaceID] {
    loadSkyLightFunctions()
    guard let fn = copySpacesForWindowsPtr else { return [] }
    // Passing a NULL CFArray segfaults inside SkyLight, and an empty one
    // returns NULL rather than an empty array. Neither is worth finding out
    // about at runtime.
    guard !windowIDs.isEmpty else { return [] }

    let ids = windowIDs.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
    guard let result = fn(connection, CGSSpaceSelector.all, ids) else { return [] }
    let spaces = result.takeRetainedValue() as? [NSNumber] ?? []
    return spaces.map { CGSSpaceID($0.uint64Value) }
}

/// Every window the WindowServer places on `space`, minimized windows
/// included. Cheaper than classifying window-by-window when the whole picture
/// is wanted: one call per space rather than one per window.
///
/// The tag arguments are in-out and deliberately zeroed — a non-zero
/// `setTags` filter was observed to drop real application windows.
func SLSWindowIDs(onSpace space: CGSSpaceID, connection: CGSConnectionID) -> [CGWindowID] {
    loadSkyLightFunctions()
    guard let fn = copyWindowsWithOptionsAndTagsPtr else { return [] }

    let spaces = [NSNumber(value: Int64(bitPattern: space))] as CFArray
    var setTags: UInt64 = 0
    var clearTags: UInt64 = 0
    guard let result = fn(
        connection,
        0, // owner pid; 0 means every process
        spaces,
        CGSWindowListOptions.all,
        &setTags,
        &clearTags
    ) else {
        return []
    }
    let windows = result.takeRetainedValue() as? [NSNumber] ?? []
    return windows.map { CGWindowID($0.uint32Value) }
}

/// The WindowServer's per-display space topology. Each element carries a
/// `Display Identifier` (a display UUID string, or the literal `"Main"` when
/// "Displays have separate Spaces" is off), a `Current Space` dictionary, and
/// an ordered `Spaces` array of `{id64, uuid, type, …}` entries.
///
/// Returned as plain Foundation types so nothing above this file has to
/// handle CoreFoundation bridging.
func CGSManagedDisplaySpaces(connection: CGSConnectionID) -> [[String: Any]] {
    loadSkyLightFunctions()
    guard let fn = copyManagedDisplaySpacesPtr,
          let result = fn(connection) else {
        return []
    }
    return result.takeRetainedValue() as? [[String: Any]] ?? []
}

/// The space currently shown on `displayIdentifier`, or nil if unknown.
/// Prefer this over the `Current Space` key in `CGSManagedDisplaySpaces`,
/// which is a point-in-time snapshot of the whole topology.
func SLSCurrentSpace(forDisplay displayIdentifier: String, connection: CGSConnectionID) -> CGSSpaceID? {
    loadSkyLightFunctions()
    guard let fn = managedDisplayGetCurrentSpacePtr else { return nil }
    let space = fn(connection, displayIdentifier as CFString)
    return space == 0 ? nil : space
}

/// The active space on the focused display, without going through the
/// per-display topology. Used as a fallback when the topology is unavailable.
func SLSActiveSpace(connection: CGSConnectionID) -> CGSSpaceID? {
    loadSkyLightFunctions()
    guard let fn = getActiveSpacePtr else { return nil }
    let space = fn(connection)
    return space == 0 ? nil : space
}

/// The type of a space. Only meaningful for IDs that came from
/// `CGSManagedDisplaySpaces` — an unknown ID reports `CGSSpaceType.invalid`
/// rather than failing.
func SLSSpaceType(of space: CGSSpaceID, connection: CGSConnectionID) -> Int32? {
    loadSkyLightFunctions()
    guard let fn = spaceGetTypePtr else { return nil }
    return fn(connection, space)
}

/// The display identifier owning `space`, or nil if unknown.
func SLSDisplayIdentifier(forSpace space: CGSSpaceID, connection: CGSConnectionID) -> String? {
    loadSkyLightFunctions()
    guard let fn = copyManagedDisplayForSpacePtr,
          let result = fn(connection, space) else {
        return nil
    }
    return result.takeRetainedValue() as String
}

/// The display currently owning the menu bar — the WindowServer's own notion
/// of which display is focused, which is what decides whose active space the
/// user means when several displays each show a different one.
func SLSActiveMenuBarDisplayIdentifier(connection: CGSConnectionID) -> String? {
    loadSkyLightFunctions()
    guard let fn = copyActiveMenuBarDisplayIdentifierPtr,
          let result = fn(connection) else {
        return nil
    }
    return result.takeRetainedValue() as String
}

#if DEBUG
/// Which space symbols the current OS actually exports. Diagnostics only —
/// this is how a new macOS release gets checked before anything is trusted to
/// work on it.
func cgsSpaceSymbolReport() -> [(name: String, resolved: Bool)] {
    loadSkyLightFunctions()
    return [
        ("SLSCopySpacesForWindows", copySpacesForWindowsPtr != nil),
        ("SLSCopyWindowsWithOptionsAndTags", copyWindowsWithOptionsAndTagsPtr != nil),
        ("SLSCopyManagedDisplaySpaces", copyManagedDisplaySpacesPtr != nil),
        ("SLSManagedDisplayGetCurrentSpace", managedDisplayGetCurrentSpacePtr != nil),
        ("SLSGetActiveSpace", getActiveSpacePtr != nil),
        ("SLSSpaceGetType", spaceGetTypePtr != nil),
        ("SLSCopyManagedDisplayForSpace", copyManagedDisplayForSpacePtr != nil),
        ("SLSCopyActiveMenuBarDisplayIdentifier", copyActiveMenuBarDisplayIdentifierPtr != nil),
        ("SLSWindowIsOrderedIn", windowIsOrderedInPtr != nil)
    ]
}
#endif

// MARK: - Dock Notifications (HIServices)
//
// `CoreDockSendNotification` is the private function the system Dock invokes
// when its own menus pick "Show All Windows" / "Mission Control" / etc.
// Posting via `DistributedNotificationCenter` with the same name string does
// not route through the Dock and is a no-op. Loaded by dlsym because the
// symbol is not exported in the SDK.

private typealias CoreDockSendNotificationType = @convention(c) (CFString, Int32) -> Void
private var hiServicesHandle: UnsafeMutableRawPointer?
private var coreDockSendNotificationPtr: CoreDockSendNotificationType?

private func loadHIServicesFunctions() {
    guard hiServicesHandle == nil else { return }

    let hiServicesPath = "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices"
    guard let handle = dlopen(hiServicesPath, RTLD_LAZY) else { return }
    hiServicesHandle = handle

    if let symbol = dlsym(handle, "CoreDockSendNotification") {
        coreDockSendNotificationPtr = unsafeBitCast(symbol, to: CoreDockSendNotificationType.self)
    }
}

func CoreDockSendNotification(_ message: String) {
    loadHIServicesFunctions()
    guard let fn = coreDockSendNotificationPtr else { return }
    fn(message as CFString, 0)
}

func slpsMakeKeyWindow(psn: inout ProcessSerialNumber, windowID: CGWindowID) {
    var bytes = [UInt8](repeating: 0, count: 0xF8)
    bytes[0x04] = 0xF8
    bytes[0x3A] = 0x10
    var wid = UInt32(windowID)
    memcpy(&bytes[0x3C], &wid, MemoryLayout<UInt32>.size)
    memset(&bytes[0x20], 0xFF, 0x10)
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}
