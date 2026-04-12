//
//  ContentView.swift
//  SoundSeen
//
//  Created by Evan Chang on 4/6/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioReactivePlayer

    var body: some View {
        MainTabView()
            .preferredColorScheme(.dark)
            .onAppear {
                audioPlayer.attachLibrary(library)
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(AudioReactivePlayer())
}
