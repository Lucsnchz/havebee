import Foundation

/// Lo que se eligió en la barra de un archivo en conflicto.
public enum ConflictChoice: Sendable, Equatable, CaseIterable {
    /// «Usar la mía».
    case mine
    /// «Usar la de ellos».
    case theirs
    /// «Marcar resuelto» (lo arreglaste a mano).
    case markResolved
}

/// La confirmación que muestra la barra de conflicto antes de resolver. Va en la misma barra porque
/// la hoja del diff no puede mostrar alertas, y pisar un archivo con un clic no se puede deshacer.
public struct ConflictPrompt: Equatable, Sendable {
    /// Qué se pierde («Se descartan tus cambios en «Order.php»…»).
    public let message: String
    /// El botón que confirma («Sí, usar la de ellos»).
    public let confirmTitle: String

    /// Qué hacer con git: en un rebase, «ours» es la rama de destino y «theirs» tu commit.
    public static func resolution(for choice: ConflictChoice, swapsOursAndTheirs: Bool) -> ConflictResolution {
        switch choice {
        case .mine: swapsOursAndTheirs ? .theirs : .ours
        case .theirs: swapsOursAndTheirs ? .ours : .theirs
        case .markResolved: .markResolved
        }
    }

    /// Si quedan marcadores de conflicto (<<<<<<<, =======, >>>>>>>) en el diff.
    public static func hasMarkers(_ diff: FileDiff?) -> Bool {
        diff?.lines.contains { $0.kind == .conflictMarker } ?? false
    }

    /// La confirmación para `choice`, o nil si se puede hacer sin preguntar (marcar resuelto un
    /// archivo que ya no tiene marcadores). `code` es el de `git status` («UU», «UD»…): si el lado
    /// elegido borró el archivo, quedarse con él es borrarlo, y eso también se avisa.
    public static func make(_ choice: ConflictChoice, fileName: String, code: String, swapsOursAndTheirs: Bool = false,
                            hasMarkers: Bool) -> ConflictPrompt? {
        let file = "«\(fileName)»"
        switch choice {
        case .markResolved:
            guard hasMarkers else { return nil }
            return ConflictPrompt(message: "Todavía quedan marcadores de conflicto (<<<<<<<) en \(file): si lo marcás como resuelto, van así al commit.",
                                  confirmTitle: "Marcar igual")
        case .mine, .theirs:
            let mine = choice == .mine
            let side = resolution(for: choice, swapsOursAndTheirs: swapsOursAndTheirs)
            // DU: lo borró HEAD («ours»); UD: lo borró la otra rama («theirs»); DD: las dos.
            let deletes = (side == .ours && ["DU", "DD"].contains(code)) || (side == .theirs && ["UD", "DD"].contains(code))
            let confirmTitle = mine ? "Sí, usar la mía" : "Sí, usar la de ellos"
            if deletes {
                let message = mine
                    ? "Tu versión borró \(file): el archivo se borra y se pierden los cambios de ellos."
                    : "La versión de ellos borró \(file): el archivo se borra y se pierden tus cambios."
                return ConflictPrompt(message: message, confirmTitle: confirmTitle)
            }
            let lost = mine ? "los cambios de ellos" : "tus cambios"
            return ConflictPrompt(message: "Se descartan \(lost) en \(file), también lo que hayas arreglado a mano.",
                                  confirmTitle: confirmTitle)
        }
    }
}
