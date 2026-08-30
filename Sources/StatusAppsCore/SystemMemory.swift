import Darwin
import Foundation

public struct SwapUsage: Equatable {
    public let total: UInt64
    public let used: UInt64

    public init(total: UInt64, used: UInt64) {
        self.total = total
        self.used = used
    }

    /// 0 when swap is disabled or not yet allocated, so callers never divide by zero.
    public var fraction: Double {
        total == 0 ? 0 : Double(used) / Double(total)
    }
}

public enum SystemMemory {
    public static func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(total: usage.xsu_total, used: usage.xsu_used)
    }
}
