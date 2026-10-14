import Foundation

/// Finds the movie fragments that landed in a .mov the recorder still writes, by its top-level
/// boxes only: a few 16-byte reads per new box, from where the last scan stopped.
///
/// AVAssetWriter writes camera.mov and screen.mov as `ftyp`, `mdat`, `moov`, then for every 2 s
/// a `mdat` with the samples and the `moof` that describes them (`movieFragmentInterval`). A
/// fragment is readable once its `moof` box is complete. A box that runs past the end of the file
/// (or has size 0, "to the end of the file") is still being written: the scan stops before it and
/// reads it again next time.
///
/// When the writer finishes the file (Stop, or a recorder that ended early while the take goes
/// on), it rewrites it in place: the boxes so far end up inside one big `mdat`, and a new `moov`
/// comes at the end. The scan then finds that second `moov`: `finished`.
///
/// Why not only AVFragmentedAssetMinder: the SDK documents fragment minding for QuickTime movies
/// with an `mvex` box (AVAsset.h, AVFragmentedAsset), and AVAssetWriter's fragmented .mov has one
/// (`canContainFragments` is true, see ReplayTests). On macOS 27.2, though, a minded
/// AVFragmentedAsset of such a file kept its first duration and posted no
/// AVAssetDurationDidChangeNotification while fragments landed (tried with fragments every 0.5 s
/// and 2 s, minding intervals of 0.25 s to 2 s, in a plain process and in an NSApplication run
/// loop), while a new opening of the same file read every fragment. Opening a movie with 1,800
/// fragments takes 3 to 7 ms. So the replay keeps a minder on its newest opening (its notification
/// opens the file again at once, where the system posts one), and this probe does the same every
/// 0.5 s.
public struct FragmentProbe: Sendable {
    public let url: URL
    /// Where the next scan starts: the first box not known to be complete.
    public private(set) var offset: UInt64 = 0
    /// Complete `moof` boxes seen.
    public private(set) var fragments = 0
    /// The `moov` box is complete: the file can be opened.
    public private(set) var hasMovie = false
    /// A second `moov` came: the writer finished the file. It grows no more.
    public private(set) var finished = false
    /// File size at the last scan.
    public private(set) var fileSize: UInt64 = 0

    public init(url: URL) { self.url = url }

    /// Scans the boxes written since the last scan. True when a new `moov` or `moof` is complete.
    /// A finished file is not scanned again.
    @discardableResult
    public mutating func scan() -> Bool {
        guard !finished, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        fileSize = size
        var found = false
        while offset + 8 <= size {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8 else { break }
            let bytes = [UInt8](header)
            var boxSize = UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            guard Self.isBoxType(bytes[4..<8]) else { break }  // Not a box header: give up until the next scan.
            if boxSize == 1 {
                guard bytes.count >= 16 else { break }
                boxSize = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            // Size 0 runs to the end of the file; a box past the end is still being written.
            guard boxSize >= 8, offset + boxSize <= size else { break }
            if type == "moof" {
                fragments += 1
                found = true
            } else if type == "moov" {
                if hasMovie { finished = true }
                found = true
                hasMovie = true
            }
            offset += boxSize
        }
        return found
    }

    /// Four printable ASCII characters, as every box type the writer uses.
    static func isBoxType(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.allSatisfy { (0x20...0x7E).contains($0) }
    }
}
