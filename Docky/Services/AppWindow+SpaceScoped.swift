//
//  AppWindow+SpaceScoped.swift
//  Docky
//
//  Bridges the registry's window model to the space queries.
//
//  Deliberately its own file so that neither side depends on the other:
//  `WindowRegistry` stays unaware that spaces exist, and `SpaceService` stays
//  unaware of `AppWindow`, which is what lets its queries be exercised with
//  synthetic input (`AppWindow`'s initialiser is not usable outside its own
//  file).
//

import Foundation

/// `AppWindow` already carries every property the space queries need, so the
/// conformance is empty.
extension AppWindow: SpaceScopedWindowRef {}
