import Foundation

/// Cell-sector seeks and NAV timestamp folds keep a menu title on its IFO clock across STC resets.
/// The wrapped reader owns its cursor lock; this lock protects packet-cell and lazy NAV-shift caches.
final class DVDTitleIOReader: TimeSeekableIOReader, @unchecked Sendable {
    struct Cell: Sendable {
        let byteStart: Int64
        let byteLength: Int64
        let startSeconds: Double
        let durationSeconds: Double
        let sourceStartSeconds: Double?
    }

    struct SeekPoint: Sendable {
        let seconds: Double
        let byteOffset: Int64
    }

    private let base: IOReader
    private let cells: [Cell]
    private let timeMap: [SeekPoint]?
    private let resolveSourceStart: (@Sendable (Int) -> Double?)?
    let mediaDuration: Double
    private let lock = NSLock()
    private var packetCell = 0
    private var shifts: [Double?]

    init(base: IOReader, cells: [Cell], duration: Double, timeMap: [SeekPoint]? = nil,
         resolveSourceStart: (@Sendable (Int) -> Double?)? = nil) {
        self.base = base
        self.cells = cells
        self.mediaDuration = duration
        self.timeMap = timeMap
        self.resolveSourceStart = resolveSourceStart
        self.shifts = cells.map { cell in cell.sourceStartSeconds.map { $0 - cell.startSeconds } }
    }

    var discImageProbeEnabled: Bool { false }
    var segmentStartTimesSeconds: [Double] { cells.map(\.startSeconds) }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        base.read(buffer, size: size)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        base.seek(offset: offset, whence: whence)
    }

    func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite,
              let index = cells.lastIndex(where: { $0.startSeconds <= max(0, seconds) }) else { return false }
        let cell = cells[index]
        let offset: Int64
        if let timeMap, timeMap.contains(where: {
            $0.byteOffset >= cell.byteStart && $0.byteOffset < cell.byteStart + cell.byteLength
        }) {
            // A map entry denotes a VOBU at or before its interval, never a bitrate estimate.
            offset = timeMap.last(where: {
                $0.seconds <= seconds && $0.byteOffset >= cell.byteStart && $0.byteOffset < cell.byteStart + cell.byteLength
            })?.byteOffset ?? cell.byteStart
        } else {
            let fraction = cell.durationSeconds > 0
                ? min(1, max(0, (seconds - cell.startSeconds) / cell.durationSeconds)) : 0
            let sectorSize: Int64 = 2048
            let sectorCount = cell.byteLength / sectorSize
            guard sectorCount > 0 else { return false }
            let sector = min(sectorCount - 1, Int64(fraction * Double(sectorCount)))
            offset = cell.byteStart + sector * sectorSize
        }
        guard base.seek(offset: offset, whence: SEEK_SET) >= 0 else { return false }
        _ = timestampShift(at: offset)
        return true
    }

    func timestampShift(at position: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard cells.isEmpty == false else { return 0 }
        if position >= 0 {
            packetCell = cells.lastIndex(where: { $0.byteStart <= position }) ?? 0
        }
        if let shift = shifts[packetCell] { return shift }
        let shift = resolveSourceStart?(packetCell).map { $0 - cells[packetCell].startSeconds }
            ?? shifts[..<packetCell].reversed().compactMap { $0 }.first ?? 0
        shifts[packetCell] = shift
        return shift
    }

    func close() { base.close() }
    func cancel() { base.cancel() }
    func makeIndependentReader() -> IOReader? {
        guard let fork = base.makeIndependentReader() else { return nil }
        let reader = DVDTitleIOReader(base: fork, cells: cells, duration: mediaDuration,
                                      timeMap: timeMap, resolveSourceStart: resolveSourceStart)
        lock.lock(); defer { lock.unlock() }
        reader.shifts = shifts
        return reader
    }
}
