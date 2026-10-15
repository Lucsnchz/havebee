import HiveCore
import SwiftUI

/// Cápsula abajo al centro para deshacer lo último: «Archivaste “Claude 2” · Deshacer».
/// Se va sola a los pocos segundos; ⌘Z hace lo mismo.
struct UndoToastView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            if let action = store.undoAction {
                HStack(spacing: 10) {
                    Text(action.message)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Button("Deshacer") { store.performUndo() }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.honey)
                        .help("Deshacer (⌘Z)")
                    Button {
                        store.dismissUndo()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cerrar")
                }
                .font(.system(size: 12.5))
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                // Siempre oscura, como un HUD: en modo claro el «Deshacer» miel no se leía sobre blanco.
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(action.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.undoAction?.id)
    }
}
