import Foundation

/// Origins that answered a ranged request at a non-zero offset with `200` and the whole body.
///
/// That answer is a property of the origin (some debrid hosts, misconfigured proxies and CDNs that
/// strip `Range`), not a transient fault: asking again gets the same 200. Before this registry the
/// reader treated it as an ordinary unproductive reconnect and spent its whole 12-step backoff ladder
/// on it, so a moov-at-end MP4 or an MKV whose Cues sit at the end hung the load for 45 s+ (engine
/// lab rows `q-range-ignored-moov-end`, `q-range-ignored-mkv`). The reader now records the origin
/// here and gives the read up at once, and `load(url:)` reopens such a source once as a
/// `sequentialOrigin` (one unranged GET read forward), which is the only shape that origin can serve.
///
/// Keyed by the URL the host passed, small and LRU like `SourceContentLengthCache`.
enum RangeIgnoringOrigins {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: [String] = []
    private static let capacity = 16

    static func mark(_ url: URL) {
        let key = url.absoluteString
        lock.lock(); defer { lock.unlock() }
        if let i = keys.firstIndex(of: key) { keys.remove(at: i) }
        keys.append(key)
        if keys.count > capacity { keys.removeFirst(keys.count - capacity) }
    }

    static func contains(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys.contains(url.absoluteString)
    }

    static func remove(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        keys.removeAll { $0 == url.absoluteString }
    }

    /// Whether a failed open is the reader's typed `originIgnoresRange` on a URL source that is not
    /// already sequential: `load()` then reopens the same URL once with `sequentialOrigin`, the same
    /// way AE#154 reroutes an HLS playlist, so no error is published for a source that can play.
    static func shouldReopenSequentially(failure: Error?, isCustomSource: Bool,
                                         isLive: Bool, alreadySequential: Bool) -> Bool {
        guard !isCustomSource, !isLive, !alreadySequential,
              let readerError = failure as? AVIOReaderError,
              case .originIgnoresRange = readerError else { return false }
        return true
    }

    /// Whether a failed load should be retried as a sequential origin: VOD over HTTP, not already
    /// sequential, and the reader saw this origin ignore `Range`.
    static func shouldRetrySequentially(url: URL, isLive: Bool, alreadySequential: Bool) -> Bool {
        guard !isLive, !alreadySequential,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return contains(url)
    }
}
