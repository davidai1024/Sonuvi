// Sonuvi — GPL-3.0.
// Shared by selection capture, the app and the native browser bridge.
enum TextLimits {
    static let characters = 200_000
    static let utf16Units = characters * 2
    static let messageBytes = 2_097_152
}
