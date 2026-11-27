import StowKit
import SwiftUI

/// For checking screens without tapping (simulator screenshots): `-tab downloads` picks a tab and
/// `-open settings,report` pushes routes on it. Routes: search, settings, report, groups, channels,
/// ytdlp, channel:<id>, group:<id>, playlist:<id> (or playlist:first), save:<video id> (the
/// save-to-playlist sheet), update (the update sheet, once a check finds one; with `-updates-url`). `-search <text>` runs a search when the search screen opens.
/// `-scroll-end` or `-scroll-to <id>` scroll screens that support it (see `launchScroll`).
enum LaunchRoutes {
    static func apply(to shell: Shell, repository: Repository, updates: UpdateChecker? = nil,
                      arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        switch value("-tab") {
        case "subscriptions": shell.select(.subscriptions)
        case "downloads": shell.select(.downloads)
        default: break
        }
        for part in (value("-open") ?? "").split(separator: ",") {
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = pieces.count > 1 ? pieces[1] : ""
            switch pieces[0] {
            case "search": shell.open(.search)
            case "settings": shell.open(.settings)
            case "report": shell.open(.report)
            case "groups": shell.open(.groups)
            case "channels": shell.open(.channels)
            case "ytdlp": shell.open(.ytdlp)
            case "channel": shell.open(.channel(argument))
            case "group": shell.open(.group(argument))
            case "playlist":
                if let id = argument == "first" ? repository.playlists.first?.id : argument { shell.open(.playlist(id)) }
            case "save":
                shell.saving = repository.item(argument)
            case "update":
                guard let updates else { break }
                Task {
                    await updates.check()
                    shell.update = updates.available
                }
            default: break
            }
        }
    }

    /// The query `-search` asks for, once per launch.
    static func takeSearch(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard !searchTaken, let index = arguments.firstIndex(of: "-search"), index + 1 < arguments.count else { return nil }
        searchTaken = true
        return arguments[index + 1]
    }

    private static var searchTaken = false
}

extension View {
    /// At launch, `-scroll-end` scrolls to the view with `id` and `-scroll-to <id>` to the one named
    /// (screenshots of a long screen's lower part).
    func launchScroll(to id: String, with proxy: ScrollViewProxy) -> some View {
        task {
            let arguments = ProcessInfo.processInfo.arguments
            let target: String
            if let index = arguments.firstIndex(of: "-scroll-to"), index + 1 < arguments.count {
                target = arguments[index + 1]
            } else if arguments.contains("-scroll-end") {
                target = id
            } else {
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            proxy.scrollTo(target, anchor: .top)
        }
    }
}
