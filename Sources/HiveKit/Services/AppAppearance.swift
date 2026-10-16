import AppKit
import SwiftUI

/// La apariencia de toda la aplicación, independiente del tema de las terminales.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, dark, light

    static let key = "appAppearance"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Seguir al sistema"
        case .dark: "Oscuro"
        case .light: "Claro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var native: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }

    static func read(_ defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }
}
