import Foundation
import Testing
@testable import HiveCore

@Suite("Conflictos: confirmar antes de pisar el archivo")
struct ConflictPromptTests {
    @Test("«Usar la mía» y «Usar la de ellos» siempre piden confirmación y dicen qué se pierde")
    func pickingASideAsks() throws {
        let mine = try #require(ConflictPrompt.make(.mine, fileName: "Order.php", code: "UU", hasMarkers: true))
        #expect(mine.message == "Se descartan los cambios de ellos en «Order.php», también lo que hayas arreglado a mano.")
        #expect(mine.confirmTitle == "Sí, usar la mía")
        let theirs = try #require(ConflictPrompt.make(.theirs, fileName: "Order.php", code: "UU", hasMarkers: false))
        #expect(theirs.message == "Se descartan tus cambios en «Order.php», también lo que hayas arreglado a mano.")
        #expect(theirs.confirmTitle == "Sí, usar la de ellos")
    }

    @Test("«Marcar resuelto» pregunta solo si todavía quedan marcadores")
    func markResolved() throws {
        #expect(ConflictPrompt.make(.markResolved, fileName: "Order.php", code: "UU", hasMarkers: false) == nil)
        let prompt = try #require(ConflictPrompt.make(.markResolved, fileName: "Order.php", code: "UU", hasMarkers: true))
        #expect(prompt.message == "Todavía quedan marcadores de conflicto (<<<<<<<) en «Order.php»: si lo marcás como resuelto, van así al commit.")
        #expect(prompt.confirmTitle == "Marcar igual")
    }

    @Test("Si el lado elegido borró el archivo, avisa que se borra")
    func deletingSide() throws {
        // UD: lo borró la otra rama. Quedarse con la de ellos lo borra; con la mía, no.
        let theirs = try #require(ConflictPrompt.make(.theirs, fileName: "Order.php", code: "UD", hasMarkers: false))
        #expect(theirs.message == "La versión de ellos borró «Order.php»: el archivo se borra y se pierden tus cambios.")
        let mine = try #require(ConflictPrompt.make(.mine, fileName: "Order.php", code: "UD", hasMarkers: false))
        #expect(mine.message.hasPrefix("Se descartan los cambios de ellos"))
        // DU: lo borraste vos (HEAD).
        let mineDeleted = try #require(ConflictPrompt.make(.mine, fileName: "Order.php", code: "DU", hasMarkers: false))
        #expect(mineDeleted.message == "Tu versión borró «Order.php»: el archivo se borra y se pierden los cambios de ellos.")
        // En un rebase se dan vuelta: «UD» es que lo borró tu commit.
        let rebase = try #require(ConflictPrompt.make(.mine, fileName: "Order.php", code: "UD", swapsOursAndTheirs: true, hasMarkers: false))
        #expect(rebase.message.hasPrefix("Tu versión borró"))
    }

    @Test("Qué lado de git usa cada botón, también en un rebase")
    func resolutionSides() {
        #expect(ConflictPrompt.resolution(for: .mine, swapsOursAndTheirs: false) == .ours)
        #expect(ConflictPrompt.resolution(for: .theirs, swapsOursAndTheirs: false) == .theirs)
        #expect(ConflictPrompt.resolution(for: .mine, swapsOursAndTheirs: true) == .theirs)
        #expect(ConflictPrompt.resolution(for: .theirs, swapsOursAndTheirs: true) == .ours)
        #expect(ConflictPrompt.resolution(for: .markResolved, swapsOursAndTheirs: true) == .markResolved)
    }

    @Test("Detecta los marcadores en el diff")
    func markers() {
        #expect(!ConflictPrompt.hasMarkers(nil))
        #expect(!ConflictPrompt.hasMarkers(FileDiff(lines: [DiffLine(id: 0, kind: .added, oldNumber: nil, newNumber: 1, text: "hola")])))
        #expect(ConflictPrompt.hasMarkers(FileDiff(lines: [DiffLine(id: 0, kind: .conflictMarker, oldNumber: nil, newNumber: 1, text: "<<<<<<< HEAD")])))
    }
}
