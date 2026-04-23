//
//  Config.swift
//  SoundSeen
//

import Foundation

enum Config {
    #if DEBUG
    static let backendBaseURL = URL(string: "http://localhost:8000")!
    #else
    static let backendBaseURL = URL(string: "https://REPLACE_AFTER_DEPLOY.up.railway.app")!
    #endif
}
