import CoreServices
import Foundation

/// En qué carpetas hubo cambios desde la última vez que se preguntó.
public struct DirectoryChanges: Equatable, Sendable {
    /// Las carpetas miradas (como se pasaron a `watch`) donde cambió algo adentro.
    public var roots: Set<String>
    /// No se sabe qué cambió (recién empezó a mirar, o macOS perdió avisos): hay que suponer que todo.
    public var all: Bool

    public init(roots: Set<String> = [], all: Bool = false) {
        self.roots = roots
        self.all = all
    }
}

/// Mira carpetas y junta dónde hubo cambios, para no tener que revisarlas todas cada vez.
public protocol DirectoryWatching: AnyObject, Sendable {
    /// Las carpetas a mirar. Si el conjunto cambia, empieza de cero: lo que pasó antes no se sabe,
    /// así que el próximo `drain` dice que cambió todo.
    func watch(_ roots: Set<String>)
    /// Lo que cambió desde el último `drain`, y vuelve a juntar desde ahora.
    func drain() -> DirectoryChanges
}

/// No mira nada: para quien pregunta, siempre cambió todo (como revisar todo cada vez).
public final class UnwatchedDirectories: DirectoryWatching {
    public init() {}
    public func watch(_ roots: Set<String>) {}
    public func drain() -> DirectoryChanges { DirectoryChanges(all: true) }
}

/// Con FSEvents: macOS avisa en qué carpetas cambió algo, lo cambie quien lo cambie (un agente, el
/// editor, git en una terminal). Cada aviso se anota en la carpeta mirada más específica que lo
/// contiene: si se miran el repo y su `.git`, un cambio en `.git` no cuenta como cambio del repo.
/// Si FSEvents no arranca, se comporta como `UnwatchedDirectories`.
public final class FSEventsDirectoryWatcher: DirectoryWatching, @unchecked Sendable {
    /// Todo pasa en esta cola: los avisos de macOS, `watch` y `drain`.
    private let queue = DispatchQueue(label: "hive.directory-watcher", qos: .utility)
    /// Cuánto junta macOS los avisos antes de mandarlos.
    private let latency: TimeInterval
    private var roots: Set<String> = []
    private var stream: FSEventStreamRef?
    private var sink: Sink?

    public init(latency: TimeInterval = 0.5) {
        self.latency = latency
    }

    deinit {
        let stream = self.stream
        queue.sync { if let stream { Self.stop(stream) } }
    }

    public func watch(_ roots: Set<String>) {
        queue.sync {
            guard roots != self.roots else { return }
            self.roots = roots
            if let stream { Self.stop(stream) }
            stream = nil
            sink = nil
            guard !roots.isEmpty else { return }
            let sink = Sink(roots: roots)
            self.sink = sink
            stream = start(sink)
        }
    }

    public func drain() -> DirectoryChanges {
        queue.sync {
            guard !roots.isEmpty else { return DirectoryChanges() }
            guard stream != nil, let sink else { return DirectoryChanges(all: true) }
            return sink.take()
        }
    }

    private func start(_ sink: Sink) -> FSEventStreamRef? {
        // El stream retiene al sink: un aviso que llega mientras se para no encuentra nada liberado.
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Sink>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Sink>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            sink.record(list, Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, sink.watched.map(\.real) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    private static func stop(_ stream: FSEventStreamRef) {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Lo que anotan los avisos de un stream. Solo se toca en `queue`.
    private final class Sink {
        /// Las carpetas miradas con su ruta real (la de los avisos: /private/var y no /var), de la más
        /// larga a la más corta, así la primera que contiene un aviso es la más específica.
        let watched: [(real: String, root: String)]
        /// Lo que pasó antes de empezar a mirar no se sabe.
        private var changes = DirectoryChanges(all: true)

        /// macOS perdió avisos o cambió un disco: no se sabe qué cambió.
        private static let lost = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

        init(roots: Set<String>) {
            watched = roots.map { (real: Self.realPath($0), root: $0) }.sorted { $0.real.count > $1.real.count }
        }

        func record(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
            for (path, flag) in zip(paths, flags) {
                if flag & Self.lost != 0 {
                    changes.all = true
                } else if let root = root(containing: path) {
                    changes.roots.insert(root)
                }
            }
        }

        func take() -> DirectoryChanges {
            defer { changes = DirectoryChanges() }
            return changes
        }

        private func root(containing path: String) -> String? {
            let path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            return watched.first { path == $0.real || path.hasPrefix($0.real + "/") }?.root
        }

        /// La de una carpeta que todavía no existe (un worktree borrado) se arma con la de la primera
        /// que sí existe hacia arriba: así se reconoce el aviso cuando la vuelvan a crear.
        private static func realPath(_ path: String) -> String {
            let standard = (path as NSString).standardizingPath
            if let resolved = realpath(standard, nil) {
                defer { free(resolved) }
                return String(cString: resolved)
            }
            let parent = (standard as NSString).deletingLastPathComponent
            guard parent != standard else { return standard }
            return (realPath(parent) as NSString).appendingPathComponent((standard as NSString).lastPathComponent)
        }
    }
}
