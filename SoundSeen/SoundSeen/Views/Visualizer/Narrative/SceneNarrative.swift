//
//  SceneNarrative.swift
//  SoundSeen
//
//  Bundle of the three scripted, non-drop narrative layers. Kept separate
//  from DropChoreography because the drop flash has historically been the
//  single cinematic moment — the other three are *preamble*, *lift*, and
//  *aftermath*, and they co-exist rather than one-shot replace each other.
//
//  Driven off AudioPlayer ticks via `tick(prevTime:currentTime:)`, same
//  contract as DropChoreography.
//

import Foundation

@MainActor
final class SceneNarrative {
    let anticipation: PreDropAnticipation
    let lift: ChorusLift
    let calm: BreakCalm

    init(state: VisualizerState) {
        self.anticipation = PreDropAnticipation(state: state)
        self.lift = ChorusLift(state: state)
        self.calm = BreakCalm(state: state)
    }

    func tick(prevTime: Double, currentTime: Double) {
        anticipation.tick(prevTime: prevTime, currentTime: currentTime)
        lift.tick(prevTime: prevTime, currentTime: currentTime)
        calm.tick(prevTime: prevTime, currentTime: currentTime)
    }
}
