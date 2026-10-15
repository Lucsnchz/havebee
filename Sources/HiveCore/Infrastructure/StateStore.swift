import Foundation

/// Guarda y lee el estado de Hive (`state.json`).
public struct StateStore: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public enum LoadResult: Equatable, Sendable {
        /// No había estado guardado (primera vez).
        case empty
        case loaded(HiveState)
        /// El archivo estaba roto: se movió a `backup` para no pisarlo.
        case corrupted(backup: URL)
        /// El archivo existe pero no se pudo leer (permisos, disco) o no se pudo apartar:
        /// no hay que escribir encima. `reason` es el error, para mostrarlo.
        case unreadable(reason: String)
    }

    public func load(now: Date = Date()) -> LoadResult {
        guard FileManager.default.fileExists(atPath: file.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return .unreadable(reason: error.localizedDescription)
        }
        do {
            return .loaded(try Self.decoder.decode(HiveState.self, from: data))
        } catch {
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("state-\(Int(now.timeIntervalSince1970)).bak.json")
            do {
                try FileManager.default.moveItem(at: file, to: backup)
            } catch {
                // Si no se puede apartar, tampoco se puede pisar: sería perderlo.
                return .unreadable(reason: error.localizedDescription)
            }
            return .corrupted(backup: backup)
        }
    }

    public func save(_ state: HiveState) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: file, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
