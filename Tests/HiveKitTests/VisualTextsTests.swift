import AppKit
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
        // Un archivo con una parte preparada y otra no está en los dos grupos, con una fila distinta en cada uno.
        let half = GitChange(code: "MM", path: "tests/InformesTabTest.php")
        #expect(half.isStaged && half.isUnstaged)
        #expect(half.stagedRowID != half.unstagedRowID)
        // La lista del diff usa los mismos nombres que el panel.
        #expect(DiffSheet.sectionTitle(staged: true, hasStaged: true) == "PREPARADOS")
        #expect(DiffSheet.sectionTitle(staged: false, hasStaged: true) == "SIN PREPARAR")
        #expect(DiffSheet.sectionTitle(staged: false, hasStaged: false) == "CAMBIOS")
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

    @Test("Uso: sin «ctx» ni el porcentaje repetido abajo")
    func usageTexts() {
        #expect(UsageBadge.helpText(72) == "72 % del contexto ocupado")
        #expect(UsageBadge.helpText(84.4) == "84 % del contexto ocupado. Conviene usar /compact.")
        let now = Date(timeIntervalSince1970: 1_790_942_400)
        let resets = now.addingTimeInterval(3 * 86_400)
        let reset = UsageReader.resetText(resets, now: now)
        #expect(UsageAccountRow.resetLine(UsageLimit(windowMinutes: 10080, usedPercent: 87, resetsAt: resets), resets: resets, now: now)
                == "La semanal \(reset)")
        #expect(UsageAccountRow.resetLine(UsageLimit(windowMinutes: 300, usedPercent: 60, resetsAt: resets), resets: resets, now: now)
                == "La de 5 horas \(reset)")
        #expect(UsageAccountRow.resetLine(UsageLimit(windowMinutes: 60, usedPercent: 60, resetsAt: resets), resets: resets, now: now)
                == "La de una hora \(reset)")
        #expect(!UsageAccountRow.resetLine(UsageLimit(windowMinutes: 10080, usedPercent: 87, resetsAt: resets), resets: resets, now: now)
            .contains("%"))
        // Codex no siempre manda la ventana: nada de «El límite de límite».
        #expect(UsageAccountRow.resetLine(UsageLimit(windowMinutes: nil, usedPercent: 70, resetsAt: resets), resets: resets, now: now)
                == "El límite \(reset)")
    }

    @Test("Uso: el nombre de cada ventana, en palabras")
    func usageWindowNames() {
        #expect(UsageAccountRow.windowName(10080) == "La semanal")
        #expect(UsageAccountRow.windowName(1440) == "La diaria")
        #expect(UsageAccountRow.windowName(300) == "La de 5 horas")
        #expect(UsageAccountRow.windowName(60) == "La de una hora")
        #expect(UsageAccountRow.windowName(43_200) == "La de 30 días")
        #expect(UsageAccountRow.windowName(90) == "La de 90 minutos")
        #expect(UsageAccountRow.windowName(1) == "La de un minuto")
        for unknown in [nil, 0, -5] as [Int?] {
            #expect(UsageAccountRow.windowName(unknown) == "El límite")
        }
    }

    @Test("Contexto: una tortita que crece desde las 12 hacia la derecha, en gris hasta 80 % (el arco miel es «trabajando»)")
    func contextPie() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let quarter = ContextPie(fraction: 0.25).path(in: rect)
        #expect(quarter.contains(CGPoint(x: 70, y: 30)), "arriba a la derecha")
        #expect(!quarter.contains(CGPoint(x: 30, y: 30)), "arriba a la izquierda")
        #expect(!quarter.contains(CGPoint(x: 70, y: 70)), "abajo a la derecha")
        // Es una torta (con el centro), no un arco como el de «trabajando».
        #expect(quarter.contains(CGPoint(x: 52, y: 48)))
        #expect(ContextPie(fraction: 0).path(in: rect).isEmpty)
        #expect(ContextPie(fraction: .nan).path(in: rect).isEmpty)
        #expect(ContextPie(fraction: 1.4).path(in: rect).contains(CGPoint(x: 30, y: 70)))
        // Gris hasta 80 %, miel desde 80 % y rojo desde 95 %, igual que el número.
        #expect(UsageMonitor.highlight(0) == nil)
        #expect(UsageMonitor.highlight(79.9) == nil)
        for (percent, token) in [(80.0, Theme.accentNSColor), (94, Theme.accentNSColor), (95, Theme.dangerNSColor)] {
            guard let color = UsageMonitor.highlight(percent) else {
                Issue.record("\(percent) % tendría que destacarse")
                continue
            }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let x = HiveContrast.resolve(NSColor(color), in: appearance)
                let y = HiveContrast.resolve(token, in: appearance)
                #expect(abs(x.redComponent - y.redComponent) < 0.01 && abs(x.greenComponent - y.greenComponent) < 0.01
                        && abs(x.blueComponent - y.blueComponent) < 0.01, "\(percent) % en \(appearance.rawValue)")
            }
        }
    }

    @Test("Git en palabras: una operación «a medias», sin «upstream» ni «en curso»")
    func gitWords() {
        for operation in GitOperation.allCases {
            #expect(operation.label.hasSuffix(" a medias"), "\(operation)")
        }
        #expect(BranchGitBadges.make(GitStatus(operation: .merge)).first?.text == "Merge a medias")
    }
}
