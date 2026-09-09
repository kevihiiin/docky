//
//  NewWindowService.swift
//  Docky
//
//  "Open a new window of this app, here."
//
//  Needed because the useful answer to clicking an app that has no window on
//  the current space is a new window on this space -- not being carried off
//  to whichever desktop the app happens to already occupy.
//
//  There is no general API for this. `NSWorkspace.openApplication` activates
//  an already-running app rather than making a window, and `open -n` starts a
//  second copy, which most Mac apps either refuse or mishandle. Synthesizing
//  Cmd-N is worse than it looks: several editors map it to "New File", so the
//  keystroke silently does the wrong thing.
//
//  What does work is asking the app through the interface it already exposes,
//  which Docky's action catalog has curated per app: either AppleScript
//  (`make new window`) or a click along a named menu path such as
//  ["File", "New Window"]. Supporting another app is a data change in
//  `MenuCatalog/actions.json`, not a code change here.
//

import AppKit
import Foundation

@MainActor
final class NewWindowService {
    static let shared = NewWindowService()

    private init() {}

    /// Whether a new window can be opened for this app without guessing.
    ///
    /// Callers use this to decide *before* acting, so that "we cannot do this"
    /// never manifests as a click that appears to do nothing.
    func canOpenNewWindow(bundleIdentifier: String) -> Bool {
        MenuCatalogService.shared.newWindowAction(forBundleIdentifier: bundleIdentifier) != nil
    }

    /// Asks the app for a new window. Returns false when no strategy exists
    /// for it, or when the strategy failed -- never a silent partial success.
    ///
    /// The app is activated first: a menu-bar click needs the target app
    /// frontmost to have a menu bar to click, and a newly created window
    /// should end up focused anyway. Activation alone does not change space,
    /// because the app has no window here to be carried to.
    @discardableResult
    func openNewWindow(bundleIdentifier: String, displayName: String) async -> Bool {
        guard let action = MenuCatalogService.shared.newWindowAction(
            forBundleIdentifier: bundleIdentifier
        ) else {
            return false
        }

        if let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first {
            runningApp.unhide()
            runningApp.activateTransferringFrontmost()
        }

        let context = CatalogActionContext(
            tile: Tile(
                id: "newwindow:\(bundleIdentifier)",
                content: .app(AppTile(bundleIdentifier: bundleIdentifier, displayName: displayName))
            ),
            modifierFlags: [],
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            appBundlePath: NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleIdentifier)?.path,
            folderPath: nil,
            filePath: nil,
            isRunning: true,
            isPinned: false,
            canTogglePin: false,
            isFinder: bundleIdentifier == "com.apple.finder"
        )

        let succeeded = await ActionExecutionService.shared.perform(action: action, context: context)
        if !succeeded {
            NSLog("[Docky] New-window action %@ failed for %@", action.id, bundleIdentifier)
        }
        return succeeded
    }
}
