//
//  SoundSeenApp.swift
//  SoundSeen
//

import SwiftUI

@main
struct SoundSeenApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var analysisStore = AnalysisStore()
    @StateObject private var jobStore = RenderJobStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(analysisStore)
                .environmentObject(jobStore)
                .task {
                    await RenderJobResumer.shared.resume(
                        library: library,
                        analysisStore: analysisStore,
                        jobStore: jobStore
                    )
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            await RenderJobResumer.shared.resume(
                                library: library,
                                analysisStore: analysisStore,
                                jobStore: jobStore
                            )
                        }
                    case .background, .inactive:
                        RenderJobResumer.shared.stopPolling()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
