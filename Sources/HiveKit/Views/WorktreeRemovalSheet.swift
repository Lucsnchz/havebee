import HiveCore
import SwiftUI

struct WorktreeRemovalSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let removal: PendingRemoval
    @State private var review: WorktreeRemovalReview?
    @State private var deleteBranch = false
    @State private var confirmation = ""
    @State private var busy = false
    @State private var loading = true

    private var branchId: UUID? { if case .branch(let id) = removal.item { id } else { nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Cerrar worktree", systemImage: "externaldrive.badge.minus")
                .font(.title2.weight(.semibold))
            if let id = branchId, let ctx = store.branchContext(id) {
                Text(ctx.branch.name).font(.headline).textSelection(.enabled)
                Text(ctx.branch.worktreePath ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(removal.message).font(.callout).foregroundStyle(.secondary)
            Divider()
            if loading { ProgressView("Revisando cambios y commits…") }
            else if let review {
                Label(review.mergeSummary, systemImage: review.unmergedCount == 0 ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(review.unmergedCount == 0 ? Theme.secondaryText : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if !review.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(review.changes.count) \(review.changes.count == 1 ? "archivo" : "archivos") con cambios sin guardar en un commit.").fontWeight(.semibold)
                        ForEach(review.changes.prefix(5)) { change in
                            Text("\(change.code)  \(change.path)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        if review.changes.count > 5 { Text("Y \(review.changes.count - 5) más…").font(.caption) }
                        Text("Al borrar el worktree se pierden estos cambios.").font(.callout)
                    }
                    .foregroundStyle(Theme.danger)
                }
                if review.locked { Text("El worktree está bloqueado. Borrarlo también quita ese bloqueo.").foregroundStyle(Theme.danger) }
                if let operation = review.operation {
                    Text("Hay un \(operation.noun) en curso. Terminalo o cancelalo antes de borrar.").foregroundStyle(Theme.danger)
                }
                if !review.valid { Text("No pude verificar la carpeta y su rama. El borrado está deshabilitado.").foregroundStyle(Theme.danger) }
                Toggle("Eliminar también la rama local «\(review.branch)»", isOn: $deleteBranch)
                    .disabled(!review.canDeleteBranch)
                Text(review.protectedBranch ? "La rama principal está protegida: se conserva."
                     : "Si dejás esta opción apagada, la rama queda disponible para crear otro worktree. La rama remota se conserva.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if review.needsTypedName(deleteBranch: deleteBranch) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Para confirmar, escribí exactamente: \(review.branch)").font(.callout.weight(.semibold))
                        TextField("Nombre de la rama", text: $confirmation).textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                }
            }
            Text("Borrar el worktree elimina su carpeta completa, incluidos .env y archivos ignorados. No se puede deshacer desde Havebee.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Solo quitar de Havebee") {
                    Task {
                        busy = true
                        if await store.performRemove(removal.item) { dismiss() }
                        busy = false
                    }
                }
                .help("Conserva la carpeta y la rama")
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancelar", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(deleteBranch ? "Borrar ambos" : "Borrar worktree", role: .destructive) { remove() }
                    .foregroundStyle(Theme.danger)
                    .disabled(!canRemove)
            }
        }
        .padding(24)
        .frame(width: 580)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { await reload() }
        .onChange(of: deleteBranch) { _, _ in confirmation = "" }
    }

    private var canRemove: Bool {
        guard !loading, let review, review.valid, review.operation == nil else { return false }
        return (!deleteBranch || review.canDeleteBranch)
            && (!review.needsTypedName(deleteBranch: deleteBranch) || confirmation == review.branch)
    }

    private func reload() async {
        loading = true
        if let branchId { review = await store.removalReview(branchId: branchId) }
        if review?.canDeleteBranch != true { deleteBranch = false }
        confirmation = ""
        loading = false
    }

    private func remove() {
        guard canRemove, let review else { return }
        busy = true
        Task {
            if await store.performRemove(removal.item, deleteWorktree: true, force: review.needsForce,
                                         deleteBranch: deleteBranch, review: review, confirmation: confirmation) {
                dismiss()
            } else { await reload() }
            busy = false
        }
    }
}
