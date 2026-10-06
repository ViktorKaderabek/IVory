import Foundation

// Small helpers on the standard collections, shared by the whole app.

extension Array {
    /// The element at `i`, or nil when the index is out of range.
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
