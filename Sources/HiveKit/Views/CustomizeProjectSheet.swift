import AppKit
import HiveCore
import SwiftUI

/// Nombre, color e ícono de un proyecto.
struct CustomizeProjectSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectId: UUID

    @State private var name = ""
    @State private var color: TintColor = .blue
    /// Tipo de ícono, símbolo, emoji e imagen elegidos (la lógica vive en HiveCore).
    @State private var form = AppearanceForm(project: Project(name: "", path: ""))
    @State private var logosLoaded = false
    @State private var loaded = false
    @FocusState private var emojiFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                if let preview {
                    ProjectTile(project: preview, size: 64)
                        .shadow(color: color.color.opacity(0.35), radius: 8, y: 3)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personalizar proyecto").font(.headline)
                    TextField("Nombre", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(TintColor.allCases) { option in
                        Button {
                            color = option
                        } label: {
                            Circle()
                                .fill(option.color.gradient)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    if option == color {
                                        Circle().strokeBorder(.white, lineWidth: 2).padding(2)
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9, weight: .heavy))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(option.label)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Ícono").font(.subheadline.weight(.semibold))
                Picker("Ícono", selection: $form.kind) {
                    ForEach(AppearanceForm.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Group {
                    switch form.kind {
                    case .logo: logoPicker
                    case .initials:
                        Text("Usa «\(preview?.initials ?? "")» sobre el color del proyecto.")
                            .foregroundStyle(.secondary)
                    case .symbol: symbolPicker
                    case .emoji: emojiPicker
                    }
                }
                .frame(height: 150, alignment: .top)
            }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .buttonStyle(.hiveProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .task { await load() }
    }

    // MARK: - Selectores

    private var logoPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !logosLoaded && form.images.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Buscando logos en el repo…").foregroundStyle(.secondary)
                }
            } else if form.images.isEmpty {
                Text("No encontré logos en el repo (favicon, apple-touch-icon, ícono de la app…). Podés elegir una imagen.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(form.images, id: \.self) { path in
                        Button {
                            form.imagePath = path
                        } label: {
                            VStack(spacing: 4) {
                                if let image = ImageCache.image(at: path) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .padding(6)
                                        .frame(width: 52, height: 52)
                                        .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 10))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(path == form.imagePath ? Theme.accent : .clear, lineWidth: 2.5)
                                        }
                                }
                                Text((path as NSString).lastPathComponent)
                                    .font(.caption2)
                                    .foregroundStyle(path == form.imagePath ? .primary : .secondary)
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(path)
                    }
                }
            }
            Button("Elegir imagen…") { chooseImage() }
        }
    }

    private var symbolPicker: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 12), spacing: 6) {
                ForEach(IconChoices.symbols, id: \.self) { name in
                    Button {
                        form.symbol = name
                    } label: {
                        Image(systemName: name)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .foregroundStyle(name == form.symbol ? .white : .primary)
                            .background(name == form.symbol ? color.color : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 12), spacing: 6) {
                ForEach(IconChoices.emojis, id: \.self) { option in
                    Button {
                        form.kind = .emoji
                        form.emoji = option
                    } label: {
                        Text(option)
                            .font(.system(size: 18))
                            .frame(width: 30, height: 30)
                            .background(option == form.emoji ? color.color.opacity(0.35) : Color.primary.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Otro:")
                TextField("", text: $form.emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .focused($emojiFocused)
                    .onChange(of: form.emoji) { _, value in
                        // Nos quedamos con el último emoji escrito; las letras no cuentan.
                        let filtered = AppearanceForm.lastEmoji(value) ?? ""
                        if filtered != value { form.typeEmoji(value) }
                    }
                    .onChange(of: emojiFocused) { _, focused in
                        if !focused { form.finishEmoji() }
                    }
                    .onSubmit { form.finishEmoji() }
                Text("⌃⌘Espacio abre el selector de emojis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Estado

    private var preview: Project? {
        guard var project = store.project(projectId) else { return nil }
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { project.name = name }
        project.color = color
        project.icon = form.icon
        return project
    }

    /// Carga el proyecto al toque y busca los logos del repo fuera del hilo principal.
    private func load() async {
        guard !loaded, let project = store.project(projectId) else { return }
        loaded = true
        name = project.name
        color = project.tint
        form = AppearanceForm(project: project)
        let findLogos = store.environment.logos
        let path = project.path
        let logos = await Task.detached(priority: .userInitiated) { findLogos(path) }.value
        form.setLogos(logos)
        logosLoaded = true
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Elegí una imagen para el ícono del proyecto"
        guard panel.runModal() == .OK, let url = panel.url, let path = store.importIcon(from: url) else { return }
        form.imagePath = path
        form.kind = .logo
    }

    private func save() {
        store.updateAppearance(projectId: projectId, name: name, color: color, icon: form.icon)
        dismiss()
    }
}
