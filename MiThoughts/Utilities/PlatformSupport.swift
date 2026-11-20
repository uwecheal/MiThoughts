import SwiftUI
#if os(macOS)
import AppKit

typealias PlatformImage = NSImage
typealias PlatformColor = NSColor

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

enum PlatformFeedback {
    /// The short "can't do that" sound (Nothing to undo, and so on).
    static func beep() {
        NSSound.beep()
    }
}
#else
import UIKit
import GameController

typealias PlatformImage = UIImage
typealias PlatformColor = UIColor

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

enum PlatformFeedback {
    /// iPhone and iPad have no beep: a light "nope" haptic where the device has one.
    static func beep() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
#endif

extension PlatformColor {
    /// sRGB components of a SwiftUI colour, 0...1.
    static func srgbComponents(of color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        #if os(macOS)
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
            return nil
        }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        #else
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
        #endif
    }
}

extension Color {
    /// The plain window background (behind the start screen).
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// The background of controls and topics in the system theme.
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

enum PlatformNotifications {
    #if os(macOS)
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
    #else
    static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #endif
}

/// The modifier keys held right now (a hardware keyboard on iPad).
struct PlatformModifiers: OptionSet {
    let rawValue: Int
    static let command = PlatformModifiers(rawValue: 1)
    static let shift = PlatformModifiers(rawValue: 2)
    static let option = PlatformModifiers(rawValue: 4)
    static let control = PlatformModifiers(rawValue: 8)

    @MainActor
    static var current: PlatformModifiers {
        var result: PlatformModifiers = []
        #if os(macOS)
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        #else
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else {
            return []
        }
        func held(_ codes: GCKeyCode...) -> Bool {
            codes.contains { keyboard.button(forKeyCode: $0)?.isPressed == true }
        }
        if held(.leftGUI, .rightGUI) { result.insert(.command) }
        if held(.leftShift, .rightShift) { result.insert(.shift) }
        if held(.leftAlt, .rightAlt) { result.insert(.option) }
        if held(.leftControl, .rightControl) { result.insert(.control) }
        #endif
        return result
    }

    /// Touch screens: a drag on empty canvas pans, and only ⌘/⇧ on a keyboard draws a selection box.
    static var dragOnEmptyCanvasSelects: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
