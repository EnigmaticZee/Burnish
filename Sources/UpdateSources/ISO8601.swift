import Foundation

/// ISO 8601 timestamps as feeds write them (`2026-08-27T14:36:01Z`, with or without fractional
/// seconds). Format styles are value types, so no formatter is allocated per date.
enum ISO8601 {
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func date(_ string: String) -> Date? {
        (try? withFractionalSeconds.parse(string)) ?? (try? plain.parse(string))
    }
}
