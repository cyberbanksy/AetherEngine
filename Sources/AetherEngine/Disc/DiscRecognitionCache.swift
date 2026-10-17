import Foundation

/// The reusable result of recognizing a DVD / Blu-ray disc structure, minus the reader-bound
/// `ConcatIOReader`. A cache hit rebuilds the reader over the caller's fresh `IOReader` from
/// `extents`, so none of the UDF / ISO9660 directory parse or the per-playlist (.mpls) / .IFO reads
/// have to run again.
struct DiscRecognition: Sendable {
    let formatHint: String
    let titles: [DiscTitle]
    let selectedTitleIndex: Int
    let extents: [(offset: Int64, length: Int64)]
    /// Per-clip presentation-offset spans for the selected multi-clip Blu-ray title; empty otherwise.
    /// Cached so a re-open (subtitle side demuxer, reload) rebuilds the same normalized timeline (AE#105).
    let clipTimeline: [ClipSpan]
    /// The selected title's EP-map seek table, cached with it so a re-open seeks the same way.
    let seekTable: DiscSeekTable?
    /// The selected DVD title's time map, cached so a re-open seeks the same way.
    let dvdTimeMap: DVDTimeMap?

    init(formatHint: String, titles: [DiscTitle], selectedTitleIndex: Int,
         extents: [(offset: Int64, length: Int64)], clipTimeline: [ClipSpan] = [],
         seekTable: DiscSeekTable? = nil, dvdTimeMap: DVDTimeMap? = nil) {
        self.seekTable = seekTable
        self.dvdTimeMap = dvdTimeMap
        self.formatHint = formatHint
        self.titles = titles
        self.selectedTitleIndex = selectedTitleIndex
        self.extents = extents
        self.clipTimeline = clipTimeline
    }
}

/// Memoizes `DiscReader.wrap` per source identity + selected title.
///
/// On a remote ISO every demuxer open re-runs disc recognition: the UDF / ISO9660 directory parse
/// plus a read of every `.mpls` (Blu-ray) or `.IFO` (DVD) over HTTP. The main pump does it at load,
/// and the subtitle side demuxer does it again on every track switch (#76), so a single subtitle
/// swap re-opens the "disc tray". Disc content at a URL is immutable within a session, so the parsed
/// title list and clip extents are safe to reuse: a hit skips straight to building the concat reader.
///
/// Thread-safe because the main demuxer and the subtitle side demuxer can open concurrently on
/// different threads. Entries are KB-scale (offset/length pairs + title metadata); a small LRU bounds
/// memory without needing explicit per-session eviction, though `AetherEngine` also clears it when a
/// new URL loads.
///
/// A second table, keyed by the image's content identity (`DiscReader.contentIdentity`), survives those
/// clears, so loading the same disc again (a host's per-play loopback URL, the next part, a re-open
/// after backing out) skips the parse too: 12–14 s for a Blu-ray over an iPhone's share. A session key
/// is bound to its identity on the first open, and every store under it lands in both tables.
enum DiscRecognitionCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [String: DiscRecognition] = [:]
    nonisolated(unsafe) private static var order: [String] = []   // LRU recency, most-recent last
    nonisolated(unsafe) private static var contentEntries: [String: DiscRecognition] = [:]
    nonisolated(unsafe) private static var contentOrder: [String] = []
    nonisolated(unsafe) private static var contentIdentityBySessionKey: [String: String] = [:]
    private static let capacity = 6

    private static func compositeKey(_ key: String, selectTitleID: Int?) -> String {
        "\(key)#\(selectTitleID ?? -1)"
    }

    static func lookup(key: String, selectTitleID: Int?) -> DiscRecognition? {
        lock.lock(); defer { lock.unlock() }
        return touch(compositeKey(key, selectTitleID: selectTitleID), in: entries, order: &order)
    }

    /// Cross-load hit for an image whose session key missed.
    static func lookup(contentIdentity: String, selectTitleID: Int?) -> DiscRecognition? {
        lock.lock(); defer { lock.unlock() }
        return touch(compositeKey(contentIdentity, selectTitleID: selectTitleID),
                     in: contentEntries, order: &contentOrder)
    }

    /// Ties a session key to the content identity of the image behind it, so stores under the key also
    /// reach the cross-load table.
    static func bind(key: String, contentIdentity: String) {
        lock.lock(); defer { lock.unlock() }
        contentIdentityBySessionKey[key] = contentIdentity
    }

    static func store(key: String, selectTitleID: Int?, _ recognition: DiscRecognition) {
        lock.lock(); defer { lock.unlock() }
        insert(compositeKey(key, selectTitleID: selectTitleID), recognition, into: &entries, order: &order)
        if let identity = contentIdentityBySessionKey[key] {
            insert(compositeKey(identity, selectTitleID: selectTitleID), recognition,
                   into: &contentEntries, order: &contentOrder)
        }
    }

    /// Drops the session table. The cross-load table stays unless `includingContent`: its keys are the
    /// image's bytes, so a different disc behind a reused URL cannot hit it.
    static func clear(includingContent: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        contentIdentityBySessionKey.removeAll()
        if includingContent {
            contentEntries.removeAll()
            contentOrder.removeAll()
        }
    }

    private static func touch(_ ck: String, in table: [String: DiscRecognition],
                              order: inout [String]) -> DiscRecognition? {
        guard let hit = table[ck] else { return nil }
        if let i = order.firstIndex(of: ck) { order.remove(at: i) }
        order.append(ck)
        return hit
    }

    private static func insert(_ ck: String, _ recognition: DiscRecognition,
                               into table: inout [String: DiscRecognition], order: inout [String]) {
        if table[ck] == nil, order.count >= capacity, let evict = order.first {
            order.removeFirst()
            table[evict] = nil
        }
        table[ck] = recognition
        if let i = order.firstIndex(of: ck) { order.remove(at: i) }
        order.append(ck)
    }
}
