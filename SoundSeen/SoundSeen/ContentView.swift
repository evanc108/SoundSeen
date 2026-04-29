//
//  ContentView.swift
//  SoundSeen
//
//  Two tabs: Library (uploaded + analyzed songs) and Live (microphone
//  mode with on-device DSP + periodic backend emotion updates).
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            LiveView()
                .tabItem {
                    Label("Live", systemImage: "waveform.and.mic")
                }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(AnalysisStore())
}
