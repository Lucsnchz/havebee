import HiveCore
import SwiftUI

/// Sigue visible después de reintentar o reabrir Hive. Copiar no lo borra ni lo envía a la IA.
struct RecoveredDraftBanner: View {
    @Environment(AppStore.self) private var store
    let sessionId: UUID
    let draft: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label("Borrador sin enviar", systemImage: "doc.text")
                    .fontWeight(.semibold)
                Spacer(minLength: 0)
                Button(copied ? "Copiado" : "Copiar borrador") {
                    ExternalApps.copyToPasteboard(draft)
                    copied = true
                }
                .help("Copiar el texto completo para pegarlo cuando la IA esté lista")
                Button("Descartar borrador", systemImage: "xmark") {
                    store.discardRecoveredDraft(sessionId)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Descartar el borrador guardado")
            }
            Text(draft)
                .lineLimit(2)
                .textSelection(.enabled)
            Text("Se guardó al fallar el inicio de Codex. Pegalo en el chat cuando esté listo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.info.opacity(0.1))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
        .onChange(of: draft) { copied = false }
    }
}
