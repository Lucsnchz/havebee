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

    @Test("Nueva rama: sin nada para copiar, el interruptor se apaga y el texto no habla de «ignorados»")
    func newBranchCopyCaption() {
        #expect(NewBranchSheet.nothingToCopy([]))
        #expect(!NewBranchSheet.nothingToCopy(nil))
        #expect(!NewBranchSheet.nothingToCopy([".env"]))
        #expect(NewBranchSheet.includesCaption([], copy: true) == "No hay .env ni otros archivos fuera de git para copiar.")
        #expect(NewBranchSheet.includesCaption(nil, copy: true) == "Buscando .env y otros archivos fuera de git…")
        #expect(NewBranchSheet.includesCaption([".env"], copy: true).hasPrefix("Se copian: "))
        #expect(NewBranchSheet.includesCaption([".env"], copy: false).hasPrefix("No se copian (encontré "))
        for mode in [BranchMode.worktree, .main] {
            #expect(!NewBranchSheet.modeExplanation(mode).isEmpty)
            #expect(!NewBranchSheet.modeExplanation(mode).contains("ignorad"))
        }
    }
}
