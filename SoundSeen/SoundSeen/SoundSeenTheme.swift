//
//  SoundSeenTheme.swift
//  SoundSeen
//

import SwiftUI

enum SoundSeenTheme {
    /// ~#8A56FF
    static let purpleAccent = Color(red: 0.541, green: 0.337, blue: 1.0)
    static let tabAccent = purpleAccent

    static let titleGradient = LinearGradient(
        colors: [
            Color.white,
            Color(red: 0.78, green: 0.72, blue: 1.0),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct SoundSeenBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.05, blue: 0.22),
                Color(red: 0.03, green: 0.03, blue: 0.09),
                Color.black,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}
