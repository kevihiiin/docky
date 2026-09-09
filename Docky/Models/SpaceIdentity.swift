//
//  SpaceIdentity.swift
//  Docky
//
//  Value types describing Mission Control spaces and which windows live on
//  them. Pure data — everything here is derived from `SpaceService`, which
//  owns the private-API calls that produce it.
//

import CoreGraphics
import Foundation

/// What kind of space this is. Only `user` desktops participate in the
/// per-space window model; fullscreen and system spaces are recorded so they
/// can be recognised and skipped rather than misread as desktops.
enum SpaceKind: Hashable {
    case user
    case other(Int32)

    init(rawType: Int32) {
        self = rawType == CGSSpaceType.user ? .user : .other(rawType)
    }

    var isUserDesktop: Bool {
        self == .user
    }
}

/// Identifies one Mission Control space.
///
/// Equality and hashing are on `id` alone, deliberately. The other fields are
/// descriptive and can legitimately change while the space itself does not —
/// a display reconfiguration rewrites `displayIdentifier` and reorders
/// `ordinal` — and if those participated in equality, every `Set<SpaceIdentity>`
/// and dictionary keyed by one would silently invalidate mid-session.
struct SpaceIdentity: Hashable, Identifiable {
    /// The WindowServer's 64-bit space id. Authoritative for the lifetime of
    /// the login session.
    let id: CGSSpaceID

    /// The space's persistent UUID, when it has one.
    ///
    /// Optional rather than a plain `String` because the WindowServer really
    /// does report an empty UUID for some spaces (observed for `id64 == 1`,
    /// which carries a `wsid` key instead). Treating "" as a valid identity
    /// would collapse those spaces together.
    let uuid: String?

    /// The display this space belongs to: a display UUID string, or the
    /// literal `"Main"` when "Displays have separate Spaces" is off.
    let displayIdentifier: String?

    let kind: SpaceKind

    /// 1-based position within its display's space list — what Mission
    /// Control shows as "Desktop 3". Presentation only; positions shift when
    /// spaces are added, removed or reordered.
    let ordinal: Int?

    static func == (lhs: SpaceIdentity, rhs: SpaceIdentity) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// One display's ordered space list, as the WindowServer reports it.
struct DisplaySpaces: Equatable {
    let displayIdentifier: String
    let spaces: [SpaceIdentity]
    let currentSpace: SpaceIdentity?
}

/// The space topology at a point in time: which spaces exist, on which
/// displays, and which one each display is currently showing.
///
/// Kept separate from `SpaceMembership` because the two change at completely
/// different rates. Topology changes when the user adds a desktop or plugs in
/// a monitor; membership changes every time any window opens, closes or moves.
/// Publishing them together would redraw the dock on every window event.
struct SpaceSnapshot: Equatable {
    /// Bumped on every recomputation, so a cached model built from this
    /// snapshot can tell whether it is still current.
    let generation: UInt64

    /// False when the private space APIs are unavailable. Callers must then
    /// behave exactly as they did before spaces were understood.
    let isAvailable: Bool

    let displays: [DisplaySpaces]

    let activeSpaceByDisplay: [String: SpaceIdentity]

    /// The display owning the menu bar — the WindowServer's own notion of
    /// which display is focused.
    let focusedDisplayIdentifier: String?

    static let unavailable = SpaceSnapshot(
        generation: 0,
        isAvailable: false,
        displays: [],
        activeSpaceByDisplay: [:],
        focusedDisplayIdentifier: nil
    )

    /// The space the user is looking at: the focused display's active space,
    /// falling back to the first display's when the focused display is
    /// unknown.
    var activeSpace: SpaceIdentity? {
        if let focusedDisplayIdentifier,
           let space = activeSpaceByDisplay[focusedDisplayIdentifier] {
            return space
        }
        return displays.first?.currentSpace
    }

    var allSpaces: [SpaceIdentity] {
        displays.flatMap(\.spaces)
    }

    func activeSpace(onDisplay displayIdentifier: String?) -> SpaceIdentity? {
        guard let displayIdentifier else { return activeSpace }
        return activeSpaceByDisplay[displayIdentifier] ?? activeSpace
    }
}

/// Which windows are on which spaces.
struct SpaceMembership: Equatable {
    let generation: UInt64

    /// A window may be resident on several spaces at once — that is how a
    /// window set to "All Desktops" is represented.
    let spacesByWindow: [CGWindowID: Set<CGSSpaceID>]

    let windowsBySpace: [CGSSpaceID: Set<CGWindowID>]

    /// Windows whose membership came from the last-known cache rather than a
    /// live answer. Callers that need to be conservative — deciding whether to
    /// open a new window versus switch spaces, say — can treat these as
    /// unknown rather than trusting them.
    let staleWindowIDs: Set<CGWindowID>

    static let empty = SpaceMembership(
        generation: 0,
        spacesByWindow: [:],
        windowsBySpace: [:],
        staleWindowIDs: []
    )

    func spaces(of windowID: CGWindowID) -> Set<CGSSpaceID> {
        spacesByWindow[windowID] ?? []
    }
}

/// The window-shaped input the space queries need.
///
/// Declaring this as a protocol rather than taking `[AppWindow]` keeps
/// `SpaceService` free of any dependency on `WindowRegistry` — the queries are
/// pure functions of their arguments, and `AppWindow`'s memberwise initialiser
/// is effectively unavailable outside its own file, so a protocol is also the
/// only way to exercise them with synthetic input.
protocol SpaceScopedWindowRef {
    /// The WindowServer's id for this window. Optional because Docky resolves
    /// it heuristically for apps that misreport it, and can fail; a window
    /// without one simply has no space answer.
    var cgWindowID: CGWindowID? { get }
    var bundleIdentifier: String { get }
    var isMinimized: Bool { get }
}
