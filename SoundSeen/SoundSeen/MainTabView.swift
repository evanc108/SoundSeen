//
//  MainTabView.swift
//  SoundSeen
//

import SwiftUI

enum AppTab: Hashable {
    case library
    case listen
}

struct MainTabView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var audioPlayer: AudioReactivePlayer
    @State private var selectedTab: AppTab = .library
    @State private var showUploadSheet = false

    var body: some View {
        Group {
            switch selectedTab {
            case .library:
                LibraryView { track in
                    audioPlayer.load(track: track)
                    selectedTab = .listen
                }
            case .listen:
                VisualizerView(onBack: { selectedTab = .library })
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectedTab != .listen {
                SoundSeenTabBar(selectedTab: $selectedTab) {
                    showUploadSheet = true
                }
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .listen, audioPlayer.activeTrackId == nil, let first = library.tracks.first {
                audioPlayer.load(track: first)
            }
        }
        .sheet(isPresented: $showUploadSheet) {
            UploadView()
                .environmentObject(library)
        }
    }
}

// MARK: - Custom tab bar (Library | + | Listen)

private struct SoundSeenTabBar: View {
    @Binding var selectedTab: AppTab
    var onAdd: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .center, spacing: 0) {
                tabSideButton(
                    title: "Library",
                    selectedSystemImage: "books.vertical.fill",
                    normalSystemImage: "books.vertical",
                    tab: .library
                )
                .frame(maxWidth: .infinity)

                Color.clear
                    .frame(width: 76, height: 1)

                tabSideButton(
                    title: "Listen",
                    selectedSystemImage: "waveform.circle.fill",
                    normalSystemImage: "waveform",
                    tab: .listen
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background {
                tabBarBackground
            }

            Button(action: onAdd) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    SoundSeenTheme.purpleAccent,
                                    Color(red: 0.38, green: 0.20, blue: 0.88),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                        .shadow(color: SoundSeenTheme.purpleAccent.opacity(0.55), radius: 14, y: 6)

                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add music")
            .offset(y: -20)
        }
        .padding(.bottom, 2)
    }

    private var tabBarBackground: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .bottom)
    }

    private func tabSideButton(
        title: String,
        selectedSystemImage: String,
        normalSystemImage: String,
        tab: AppTab
    ) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: selectedTab == tab ? selectedSystemImage : normalSystemImage)
                    .font(.system(size: 22, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(selectedTab == tab ? SoundSeenTheme.tabAccent : Color.white.opacity(0.42))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MainTabView()
        .environmentObject(LibraryStore())
        .environmentObject(AudioReactivePlayer())
        .preferredColorScheme(.dark)
}
