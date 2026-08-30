import Foundation

/// Compact, fixed-width renderings for a menu where every row has to line up.
public enum Formatters {

    /// Bytes as the menu bar shows them: `4.6G`, `188M`, `912K`.
    public static func memory(_ bytes: UInt64) -> String {
        let kilobyte = 1024.0
        let value = Double(bytes)

        if value >= kilobyte * kilobyte * kilobyte {
            return String(format: "%.1fG", value / (kilobyte * kilobyte * kilobyte))
        }
        if value >= kilobyte * kilobyte {
            return String(format: "%.0fM", value / (kilobyte * kilobyte))
        }
        if value >= kilobyte {
            return String(format: "%.0fK", value / kilobyte)
        }
        return "\(bytes)B"
    }

    /// Coarse on purpose: at a glance you want "this has been up for days", not the seconds.
    public static func uptime(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    public static func ports(_ ports: [UInt16]) -> String {
        ports.map { ":\($0)" }.joined(separator: ", ")
    }

    /// Left-aligned padding to a fixed column width; longer values are left intact rather than
    /// truncated, since a wrong port number is worse than a ragged column.
    public static func pad(_ value: String, to width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    public static func swap(_ usage: SwapUsage) -> String {
        let percent = Int((usage.fraction * 100).rounded())
        return "Swap \(memory(usage.used)) / \(memory(usage.total)) (\(percent)%)"
    }
}
