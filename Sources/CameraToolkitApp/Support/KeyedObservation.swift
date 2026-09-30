import Observation

/// Observation by key: a scope that calls `track(key)` while it runs is told
/// when that key is touched — and not when any other key is.
///
/// A tile of the board asks a handful of questions about its own files (whose
/// they are, whether they are selected, where they are stored). Answering
/// them from one shared revision counter — as a single observed property does
/// — makes every tile draw again whenever any file's answer changes: one
/// Move to Event re-ran every tile the lazy stack had ever built. With keys, a
/// change is announced to the tiles of the files it changed.
///
/// A mutation that cannot say which keys it changed calls `touchAll()`, which
/// every tracked key hears.
@MainActor
final class KeyedObservation<Key: Hashable>: Observable {
    /// The observation keys. Only its subscript is used: a key path through
    /// it names one key, and two paths with equal keys are the same path.
    struct Keys {
        subscript(key: Key) -> Int { 0 }
    }

    private let registrar = ObservationRegistrar()
    private var keys = Keys()
    /// Bumped by `touchAll()`; every key's reader also depends on it.
    private var everything = 0

    init() {}

    /// Registers the running scope's dependency on `key` (and on `touchAll`).
    func track(_ key: Key) {
        registrar.access(self, keyPath: \KeyedObservation<Key>.everything)
        registrar.access(self, keyPath: \KeyedObservation<Key>.keys[key])
    }

    /// Tells the scopes that tracked `key`.
    func touch(_ key: Key) {
        registrar.withMutation(of: self, keyPath: \KeyedObservation<Key>.keys[key]) {}
    }

    /// Tells the scopes that tracked any key.
    func touchAll() {
        registrar.withMutation(of: self, keyPath: \KeyedObservation<Key>.everything) { everything &+= 1 }
    }
}
