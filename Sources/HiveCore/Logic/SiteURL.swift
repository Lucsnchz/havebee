import Foundation

/// URL del sitio de una rama, para «Abrir sitio».
public enum SiteURL {
    /// Prioridad: `preview.url` de polyscope.json (con `{{folder}}`), después Herd.
    /// - Parameters:
    ///   - dir: carpeta de la rama (la principal o su worktree).
    ///   - projectPath: carpeta principal (si el worktree no tiene polyscope.json, se usa el suyo).
    public static func url(for dir: String, projectPath: String, herd: HerdSites?,
                           read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> String? {
        let folder = (dir as NSString).lastPathComponent
        for root in [dir, projectPath] {
            let file = (root as NSString).appendingPathComponent("polyscope.json")
            if let template = read(file).flatMap(JSONValue.parse)?["preview"]?["url"]?.string, !template.isEmpty {
                return fill(template, folder: folder)
            }
        }
        return herd?.url(for: dir)
    }

    /// Reemplaza `{{folder}}` (con o sin espacios adentro de las llaves).
    public static func fill(_ template: String, folder: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*folder\s*\}\}"#) else { return template }
        let range = NSRange(template.startIndex..., in: template)
        return regex.stringByReplacingMatches(in: template, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: folder))
    }
}
