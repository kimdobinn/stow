import Foundation

/// The running alarm as the phone remote (Remote/AlarmRemote) sees and drives it.
extension AlarmController: AlarmRunControl {
    func runStatus() async -> AlarmRunStatus {
        let phase = phase
        let nowPlaying: NowPlaying? = switch phase {
        case .starting, .playing: await services.player.nowPlaying()
        case .idle, .preparing, .alarmSound: nil
        }
        // The run may have ended while the player answered.
        guard let runner, self.phase != .idle else { return .ended }
        return AlarmRunStatus(phase: self.phase, playlist: runner.playlist.map(\.video), nowPlaying: nowPlaying,
                              outputName: runner.output?.name, volume: runner.outputVolume)
    }

    var knownVideos: [Video] {
        guard let state = host?.currentState else { return [] }
        return state.inbox.map(\.video) + state.recentVideos.values.flatMap { $0 }
    }

    func perform(_ action: PlaybackAction) async {
        switch phase {
        case .starting, .playing: await services.player.perform(action)
        case .idle, .preparing, .alarmSound: break
        }
    }

    func setOutputVolume(_ volume: Int) {
        runner?.setOutputVolume(volume)
    }

    func pushToPhones(_ data: [String: String]) {
        host?.pushToPhones(data)
    }

    func log(_ level: LogLevel, _ message: String) {
        host?.logAlarm(level, message)
    }
}
