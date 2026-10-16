import Foundation
import HiveCore
import SwiftUI
import Testing
@testable import HiveKit

/// Textos y nombres de la interfaz: una sola manera de decir cada cosa.
@MainActor
@Suite("Textos de la interfaz")
struct VisualTextsTests {
    @Test("«Cambios»: un solo ícono y «Sin preparar» al lado de «Preparados»")
    func changesNaming() {
        #expect(GitCounters.changesSymbol == "plusminus")
        #expect(ChangesList.unstagedTitle(hasStaged: true) == "Sin preparar")
        #expect(ChangesList.unstagedTitle(hasStaged: false) == "Cambios")
        #expect(SessionStatusBar.changesLabel(0) == "Sin cambios")
        #expect(SessionStatusBar.changesLabel(1) == "1 cambio")
        #expect(SessionStatusBar.changesLabel(3) == "3 cambios")
    }
}
