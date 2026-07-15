// Q3EIntents.swift — App Intents: "Launch Quake III Mod" appears as a
// native action in the Shortcuts app (and via Siri). The mod parameter
// is the fs_game folder name ("q3ut4" for Urban Terror, "cpma",
// "missionpack" for Team Arena, "baseq3" for stock).
//
// A URL-scheme sibling exists for plain Open-URL shortcuts:
//   quake3e://play?game=q3ut4

import AppIntents

@available(iOS 16.0, *)
struct LaunchModIntent: AppIntent {
    static var title: LocalizedStringResource = "Launch Quake III Mod"
    static var description = IntentDescription(
        "Opens Quake3e directly into a mod. The mod name is its folder: q3ut4 (Urban Terror), cpma, missionpack (Team Arena), baseq3 (stock)."
    )
    static var openAppWhenRun = true

    @Parameter(title: "Mod folder", default: "baseq3")
    var mod: String

    @MainActor
    func perform() async throws -> some IntentResult {
        Q3E_RequestMod(mod)
        return .result()
    }
}

@available(iOS 16.0, *)
struct Q3EAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LaunchModIntent(),
            phrases: ["Launch a mod in \(.applicationName)"],
            shortTitle: "Launch mod",
            systemImageName: "gamecontroller"
        )
    }
}
