//
//  Config.swift
//  SoundSeen
//

import Foundation

enum Config {
    /// Base URL for the SoundSeen backend. Localhost works from the iOS Simulator
    /// because the simulator shares the host's loopback. For a physical device,
    /// change this to your Mac's LAN address.
    static let backendBaseURL = URL(string: "http://localhost:8000")!
}
