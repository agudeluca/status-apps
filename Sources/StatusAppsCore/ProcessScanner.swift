import Darwin
import Foundation

/// Reads process state straight from `libproc`, the same source `lsof` and Activity Monitor use.
///
/// Every lookup is best-effort: processes die between calls and processes owned by other users
/// return `EPERM`. Those are skipped silently — a scan returns fewer rows rather than failing.
public enum ProcessScanner {

    /// Every process owned by the current user that is listening on at least one TCP port.
    public static func scanListeningProcesses() -> [RunningProcess] {
        let uid = getuid()
        return allPIDs().compactMap { pid in
            guard let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { return nil }
            return RunningProcess(
                pid: pid,
                processGroupID: Int32(bitPattern: info.pbi_pgid),
                executablePath: executablePath(pid) ?? comm(info),
                arguments: arguments(pid),
                workingDirectory: workingDirectory(pid) ?? "",
                startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
                physicalFootprint: physicalFootprint(pid),
                listeningPorts: ports
            )
        }
    }

    // MARK: - Process enumeration

    static func allPIDs() -> [pid_t] {
        var capacity = 4096
        // proc_listpids fills as much as fits, so a full buffer means we may have been truncated.
        while capacity <= 1 << 20 {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &buffer, Int32(MemoryLayout<pid_t>.size * capacity))
            guard bytes > 0 else { return [] }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            if count < capacity { return buffer[0..<count].filter { $0 > 0 } }
            capacity *= 2
        }
        return []
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    // MARK: - Sockets

    /// Local ports of every TCP socket this process holds in the LISTEN state.
    static func listeningPorts(_ pid: pid_t) -> [UInt16] {
        let probe = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard probe > 0 else { return [] }

        // Descriptors can be opened between sizing and reading, so ask for some headroom.
        let slots = Int(probe) / MemoryLayout<proc_fdinfo>.size + 32
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: slots)
        let bytes = proc_pidinfo(
            pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(MemoryLayout<proc_fdinfo>.size * slots)
        )
        guard bytes > 0 else { return [] }

        var ports = Set<UInt16>()
        for index in 0..<(Int(bytes) / MemoryLayout<proc_fdinfo>.size) {
            let descriptor = descriptors[index]
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            guard let port = listeningPort(pid: pid, fd: descriptor.proc_fd) else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    private static func listeningPort(pid: pid_t, fd: Int32) -> UInt16? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { return nil }
        guard info.psi.soi_kind == SOCKINFO_TCP else { return nil }

        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }

        // insi_lport is stored in network byte order.
        return UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
    }

    // MARK: - Per-process details

    static func physicalFootprint(_ pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : 0
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Full argument vector via `KERN_PROCARGS2`.
    ///
    /// The buffer holds argc, then the executable path, then NUL padding, then argc
    /// NUL-terminated arguments. Environment variables follow, and are ignored.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // alignment padding

        var arguments: [String] = []
        var current: [UInt8] = []
        while index < size, arguments.count < argc {
            if buffer[index] == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return arguments
    }

    private static func comm(_ info: proc_bsdinfo) -> String {
        var info = info
        return withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
        }
    }
}
