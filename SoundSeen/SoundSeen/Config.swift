//
//  Config.swift
//  SoundSeen
//

import Foundation

enum Config {
    #if DEBUG
    static let backendBaseURL = URL(string: "http://localhost:8000")!
    #else
    static let backendBaseURL = URL(string: "https://soundseen-api-production.up.railway.app")!
    #endif
}
