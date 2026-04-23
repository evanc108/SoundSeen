//
//  ContentView.swift
//  SoundSeen
//
//  Single-surface app: Library is the home, and the analyzed player is
//  reached by tapping a track. No tab bar, no realtime FFT mode —
//  SoundSeen MVP is about songs you've uploaded and had analyzed.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        LibraryView()
            .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
}
