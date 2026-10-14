import WorkoutDomain

struct SignalMoment: Equatable, Sendable {
    var countdown: Int?
    var status: WorkoutRun.Snapshot.Status
    var stage: ScheduledStage?
    var secondsLeft: Int

    init(_ state: WorkoutTimerFeature.State) {
        countdown = state.countdown?.remaining
        status = state.snapshot.status
        stage = state.snapshot.currentStage
        secondsLeft = Int((state.snapshot.stageRemaining.inMilliseconds + 999) / 1_000)
    }
}

struct SignalEvent: Equatable, Sendable {
    var tone: CueTone
    var announcement: StageAnnouncement?
}

struct SignalTrack: Equatable, Sendable {
    var last: SignalMoment?
    var announcedStageIndex: Int?
    var cueRevision = 0

    mutating func update(_ moment: SignalMoment) -> SignalEvent? {
        defer { last = moment }
        guard let previous = last else {
            if moment.status == .running || moment.status == .awaitingUser {
                announcedStageIndex = moment.stage?.index
            }
            return moment.countdown == nil ? nil : SignalEvent(tone: .countdown)
        }
        if let digit = moment.countdown {
            return digit == previous.countdown ? nil : SignalEvent(tone: .countdown)
        }
        if moment.status == .finished {
            return previous.status == .finished ? nil : SignalEvent(tone: .finish)
        }
        guard moment.status == .running || moment.status == .awaitingUser, let stage = moment.stage else { return nil }

        if stage.index != announcedStageIndex {
            announcedStageIndex = stage.index
            return SignalEvent(tone: .stageStart, announcement: StageAnnouncement(stage: stage))
        }
        if moment.status == .running, previous.status != .running || previous.countdown != nil {
            return SignalEvent(tone: .stageStart)
        }
        if moment.status == .running, previous.stage?.index == stage.index,
           moment.secondsLeft != previous.secondsLeft, (1...3).contains(moment.secondsLeft) {
            return SignalEvent(tone: .countdown)
        }
        return nil
    }
}
