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
    }

    public func load(now: Date = Date()) -> LoadResult {
        guard let data = try? Data(contentsOf: file) else { return .empty }
        do {
            return .loaded(try Self.decoder.decode(HiveState.self, from: data))
        } catch {
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("state-\(Int(now.timeIntervalSince1970)).bak.json")
            try? FileManager.default.moveItem(at: file, to: backup)
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
