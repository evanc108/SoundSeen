//
//  LibraryView.swift
//  SoundSeen
//

import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""

    /// Play track and switch to the listener (handled by parent).
    var onPlayTrack: (LibraryTrack) -> Void

    private var filtered: [LibraryTrack] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return library.tracks }
        return library.tracks.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SoundSeenBackground()

                Group {
                    if library.tracks.isEmpty {
                        emptyState
                    } else if filtered.isEmpty {
                        noSearchResults
                    } else {
                        trackList
                    }
                }
            }
            .navigationTitle("Your Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(library.tracks.count) track\(library.tracks.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SoundSeenTheme.purpleAccent.opacity(0.42))
                        .clipShape(Capsule())
                }
            }
            .searchable(text: $query, prompt: "Search tracks or artists")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            SoundSeenTheme.tabAccent.opacity(0.9),
                            Color(red: 0.95, green: 0.45, blue: 0.75),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("No tracks yet")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Tap the + button below to add MP3, M4A, or other audio files. They’ll appear here.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("No matches")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Try a different search.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackList: some View {
        List {
            Section {
                ForEach(filtered) { track in
                    Button {
                        onPlayTrack(track)
                    } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.45, green: 0.28, blue: 0.85).opacity(0.9),
                                            Color(red: 0.85, green: 0.35, blue: 0.55).opacity(0.85),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 52, height: 52)
                                .overlay {
                                    Image(systemName: "waveform")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.95))
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                if !track.artist.isEmpty {
                                    Text(track.artist)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Text(track.isBundled ? "Included with SoundSeen" : track.addedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer(minLength: 0)

                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(SoundSeenTheme.purpleAccent.opacity(0.9))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.white.opacity(0.06))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !track.isBundled {
                            Button(role: .destructive) {
                                library.remove(track)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("\(library.tracks.count) track\(library.tracks.count == 1 ? "" : "s")")
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
    }
}

#Preview {
    LibraryView { _ in }
        .environmentObject(LibraryStore())
}
