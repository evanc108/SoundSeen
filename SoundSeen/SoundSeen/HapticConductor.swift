//
//  HapticConductor.swift
//  SoundSeen
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

enum HapticEmotionEvent {
    case beat(strength: CGFloat)
    case sectionChange(SongStructureKind)
    case dropImpact
}

protocol HapticConductor: AnyObject {
    func handle(event: HapticEmotionEvent)
}

final class NullHapticConductor: HapticConductor {
    func handle(event: HapticEmotionEvent) {}
}

#if canImport(UIKit)
final class UIKitHapticConductor: HapticConductor {
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notif = UINotificationFeedbackGenerator()

    init() {
        soft.prepare()
        rigid.prepare()
        notif.prepare()
    }

    func handle(event: HapticEmotionEvent) {
        switch event {
        case .beat(let strength):
            soft.impactOccurred(intensity: min(1, max(0.15, strength)))
            soft.prepare()
        case .sectionChange(let kind):
            if kind == .buildup {
                rigid.impactOccurred(intensity: 0.5)
                rigid.prepare()
            }
        case .dropImpact:
            notif.notificationOccurred(.success)
            notif.prepare()
        }
    }
}
#endif
