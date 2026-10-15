import AppKit
import HiveCore
import SwiftUI

/// Bienvenida: la primera vez, sin proyectos. Tres pasos y una zona para soltar carpetas.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(nsImage: Self.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                    Text("Bienvenido a Hive")
                        .font(.system(size: 28, weight: .bold))
                    Text("Tus sesiones de Claude Code, Codex, Gemini y la terminal, ordenadas por proyecto y rama.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    WelcomeStep(number: 1, title: "Agregá tus repos", detail: "⌘O, podés elegir varios")
                    WelcomeStep(number: 2, title: "Creá una rama o worktree", detail: "para trabajar en paralelo sin pisarte")
                    WelcomeStep(number: 3, title: "Abrí Claude, Codex o una terminal", detail: "⌘T")
                }
                .frame(maxWidth: 420, alignment: .leading)
                dropZone
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(dropTargeted ? Theme.accent : .secondary)
            Text("Soltá acá las carpetas de tus repos")
                .font(.headline)
            Button("Elegir carpetas…") { store.addProjectInteractive() }
                .buttonStyle(.hiveProminent)
                .controlSize(.large)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: 520)
        .background(dropTargeted ? Theme.accent.opacity(0.08) : Color.primary.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(dropTargeted ? Theme.accent : Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
            guard !folders.isEmpty else { return false }
            Task { await store.addProjects(folders) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    static var appIcon: NSImage {
        NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }
}

private struct WelcomeStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
