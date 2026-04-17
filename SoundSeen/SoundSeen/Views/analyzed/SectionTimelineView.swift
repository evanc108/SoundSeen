//
//  SectionTimelineView.swift
//  SoundSeen
//
//  Two-row summary strip for the Analyzed Player: a colored bar showing
//  section boundaries + energy profile, and a label row with the current
//  section's name and timecode. Colors come from the backend's
//  `energyProfile` string; unknown values fall back to gray.
//

import SwiftUI

struct SectionTimelineView: View {
    let sections: [SongSection]
    let currentTime: TimeInterval
    let totalDuration: Double

    private let barHeight: CGFloat = 22
    private let rowSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            bar
                .frame(height: barHeight)
            labelRow
        }
    }

    // MARK: - Bar

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let safeTotal = max(totalDuration, 0.001)
            let active = currentSection

            ZStack(alignment: .topLeading) {
                // Underlying track so unmapped time (e.g. gaps) shows.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))

                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    let geom = segmentGeometry(section: section,
                                               width: width,
                                               total: safeTotal)
                    let isActive = (active?.start == section.start
                                    && active?.end == section.end)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(color(for: section.energyProfile))
                        if isActive {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.white, lineWidth: 2)
                        }
                    }
                    .frame(width: geom.width, height: height)
                    .offset(x: geom.x)
                }

                // Playhead
                let playheadX = CGFloat(min(max(currentTime, 0), safeTotal) / safeTotal) * width
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .offset(x: max(0, min(width - 2, playheadX - 1)))
                    .shadow(color: Color.black.opacity(0.45), radius: 3, y: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: - Label row

    private var labelRow: some View {
        HStack(spacing: 8) {
            if let section = currentSection {
                Text(section.label.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SoundSeenTheme.tabAccent)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(SoundSeenTheme.tabAccent.opacity(0.7))
                Text("\(formatTime(section.start))–\(formatTime(section.end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(SoundSeenTheme.tabAccent.opacity(0.85))
            } else {
                Text("—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SoundSeenTheme.tabAccent)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Geometry / lookup

    private struct SegmentGeometry {
        let x: CGFloat
        let width: CGFloat
    }

    /// Pixel geometry for a single section segment. Enforces a minimum
    /// width so very short sections stay visible.
    private func segmentGeometry(section: SongSection,
                                 width: CGFloat,
                                 total: Double) -> SegmentGeometry {
        let start = max(0, min(section.start, total))
        let end = max(start, min(section.end, total))
        let rawX = CGFloat(start / total) * width
        let rawWidth = CGFloat((end - start) / total) * width
        let minWidth: CGFloat = 3
        let effectiveWidth = max(minWidth, rawWidth)
        // If the segment is at the very end, shift leftward to keep it in bounds.
        let clampedX = min(rawX, max(0, width - effectiveWidth))
        return SegmentGeometry(x: clampedX, width: effectiveWidth)
    }

    private var currentSection: SongSection? {
        for section in sections {
            if currentTime >= section.start && currentTime < section.end {
                return section
            }
        }
        return nil
    }

    private func color(for energyProfile: String) -> Color {
        switch energyProfile {
        case "minimal":  return Color(red: 0.30, green: 0.45, blue: 0.70)
        case "fading":   return Color(red: 0.35, green: 0.42, blue: 0.55)
        case "building": return Color(red: 0.85, green: 0.65, blue: 0.20)
        case "moderate": return Color(red: 0.50, green: 0.45, blue: 0.60)
        case "high":     return Color(red: 0.90, green: 0.30, blue: 0.70)
        case "intense":  return Color(red: 0.92, green: 0.25, blue: 0.25)
        default:         return Color.gray.opacity(0.5)
        }
    }

    private func formatTime(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
