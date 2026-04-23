//
//  SoundSeenApp.swift
//  SoundSeen
//

import SwiftUI

@main
struct SoundSeenApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var analysisStore = AnalysisStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(analysisStore)
        }
    }
}
