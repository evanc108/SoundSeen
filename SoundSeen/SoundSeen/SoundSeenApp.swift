//
//  SoundSeenApp.swift
//  SoundSeen
//
//  Created by Evan Chang on 4/6/26.
//

import SwiftUI

@main
struct SoundSeenApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var audioPlayer = AudioReactivePlayer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(audioPlayer)
        }
    }
}
