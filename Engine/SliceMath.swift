import Foundation

/// The one layout constant every streaming path shares: a file is walked in
/// fixed 1 MiB plaintext slices, and chunk boundaries must always fall on
/// slice multiples so no slice ever straddles two chunk documents.
/// (In the encryption era this was `CryptoEngine.sliceSize`; the plaintext
/// layout kept the exact same arithmetic.)
enum SliceMath {
    static let sliceSize: Int64 = 1024 * 1024
}
