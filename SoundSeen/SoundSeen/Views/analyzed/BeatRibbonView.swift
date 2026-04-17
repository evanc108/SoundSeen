//
//  BeatRibbonView.swift
//  SoundSeen
//
//  Horizontal strip of upcoming beat ticks for the Analyzed Player.
//  Binary-searches the first beat at/after the current playhead and
//  draws only the 8s window ahead. Rendered via Canvas for perf since
//  the parent view re-runs the body every AudioPlayer tick.
//

import SwiftUI

struct BeatRibbonView: View {
    let beats: [BeatEvent]
    let currentTime: TimeInterval

    /// Seconds of lookahead shown in the ribbon.
    private let windowSeconds: Double = 8.0

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height

            // Background for legibility over the mood palette.
            let bgRect = CGRect(origin: .zero, size: size)
            let bgPath = Path(roundedRect: bgRect, cornerRadius: 10)
            context.fill(bgPath, with: .color(Color.white.opacity(0.05)))

            // Playhead at the left edge.
            let playheadRect = CGRect(x: 0, y: 0, width: 2, height: height)
            let playheadPath = Path(roundedRect: playheadRect, cornerRadius: 1)
            context.fill(playheadPath, with: .color(Color.white.opacity(0.7)))

            guard !beats.isEmpty, width > 0 else { return }

            let windowEnd = currentTime + windowSeconds
            let startIdx = firstIndex(atOrAfter: currentTime)

            let downbeatHeight: CGFloat = 20
            let downbeatWidth: CGFloat = 3
            let offbeatHeight: CGFloat = 8
            let offbeatWidth: CGFloat = 2

            let downbeatShadow = GraphicsContext.Shading.color(Color.black.opacity(0.35))

            var i = startIdx
            while i < beats.count {
                let beat = beats[i]
                if beat.time > windowEnd { break }
                let progress = (beat.time - currentTime) / windowSeconds
                let x = CGFloat(progress) * width

                if beat.isDownbeat {
                    let rect = CGRect(
                        x: x - downbeatWidth / 2,
                        y: (height - downbeatHeight) / 2,
                        width: downbeatWidth,
                        height: downbeatHeight
                    )
                    let path = Path(roundedRect: rect, cornerRadius: downbeatWidth / 2)
                    // Subtle drop shadow for downbeats.
                    var shadowContext = context
                    shadowContext.addFilter(.shadow(color: Color.black.opacity(0.35),
                                                   radius: 2, x: 0, y: 1))
                    shadowContext.fill(path, with: .color(Color.white.opacity(0.9)))
                    _ = downbeatShadow
                } else {
                    let rect = CGRect(
                        x: x - offbeatWidth / 2,
                        y: (height - offbeatHeight) / 2,
                        width: offbeatWidth,
                        height: offbeatHeight
                    )
                    let path = Path(roundedRect: rect, cornerRadius: offbeatWidth / 2)
                    context.fill(path, with: .color(Color.white.opacity(0.55)))
                }

                i += 1
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Upcoming beats")
    }

    /// Binary-search the first index whose `time >= target`. Returns
    /// `beats.count` if no such beat exists.
    private func firstIndex(atOrAfter target: Double) -> Int {
        var lo = 0
        var hi = beats.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].time < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
