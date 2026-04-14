//
//  HapticConductor.swift
//  SoundSeen
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

enum HapticIntensityMode: String, CaseIterable, Sendable {
    case subtle
    case balanced
    case intense

    var label: String {
        switch self {
        case .subtle: return "Subtle"
        case .balanced: return "Balanced"
        case .intense: return "Intense"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .subtle: return 0.65
        case .balanced: return 1.0
        case .intense: return 1.28
        }
    }
}

enum HapticEmotionEvent {
    case beat(strength: CGFloat)
    case sectionChange(SongStructureKind)
    case dropImpact
}

protocol HapticConductor: AnyObject {
    func handle(event: HapticEmotionEvent)
    func setIntensityMode(_ mode: HapticIntensityMode)
}

final class NullHapticConductor: HapticConductor {
    func handle(event: HapticEmotionEvent) {}
    func setIntensityMode(_ mode: HapticIntensityMode) {}
}

#if canImport(UIKit)
final class UIKitHapticConductor: HapticConductor {
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notif = UINotificationFeedbackGenerator()
    private var intensityMode: HapticIntensityMode = .balanced

    init() {
        soft.prepare()
        rigid.prepare()
        notif.prepare()
    }

    func setIntensityMode(_ mode: HapticIntensityMode) {
        intensityMode = mode
    }

    func handle(event: HapticEmotionEvent) {
        switch event {
        case .beat(let strength):
            let scaled = strength * intensityMode.multiplier
            soft.impactOccurred(intensity: min(1, max(0.12, scaled)))
            soft.prepare()
        case .sectionChange(let kind):
            if kind == .buildup {
                rigid.impactOccurred(intensity: min(1, 0.5 * intensityMode.multiplier))
                rigid.prepare()
            }
        case .dropImpact:
            notif.notificationOccurred(.success)
            notif.prepare()
        }
    }
}
#endif
