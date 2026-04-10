//
//  ContentView.swift
//  SoundSeen
//
//  Created by Evan Chang on 4/6/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainTabView()
            .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environmentObject(LibraryStore())
        .environmentObject(AudioReactivePlayer())
}
