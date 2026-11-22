import AppKit
import Foundation
import IOKit.ps
import Metal

/// One piece of system information the greeting can show. `GreeterConfig`
/// stores the user's chosen subset and order as `[InfoField]`.
enum InfoField: String, Codable, CaseIterable, Identifiable {
    case os, kernel, shell, terminal, theme, display, uptime, cpu, memory, disk,
         host, architecture, gpu, battery, loadAverage, packages, locale, hostname, username

    var id: String { rawValue }

    /// Short key printed next to the bullet in the rendered greeting —
    /// unchanged for the original ten fields so existing greetings don't shift.
    var key: String {
        switch self {
        case .os: return "os"
        case .kernel: return "ker"
        case .shell: return "sh"
        case .terminal: return "term"
        case .theme: return "theme"
        case .display: return "disp"
        case .uptime: return "up"
        case .cpu: return "cpu"
        case .memory: return "ram"
        case .disk: return "disk"
        case .host: return "host"
        case .architecture: return "arch"
        case .gpu: return "gpu"
        case .battery: return "bat"
        case .loadAverage: return "load"
        case .packages: return "pkgs"
        case .locale: return "locale"
        case .hostname: return "hostname"
        case .username: return "user"
        }
    }

    /// Label shown for this field in the Greeter panel's info picker.
    var title: String {
        switch self {
        case .os: return "Operating system"
        case .kernel: return "Kernel"
        case .shell: return "Shell"
        case .terminal: return "Terminal"
        case .theme: return "Interface theme"
        case .display: return "Display resolution"
        case .uptime: return "Uptime"
        case .cpu: return "Processor"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .host: return "Mac model"
        case .architecture: return "Architecture"
        case .gpu: return "GPU"
        case .battery: return "Battery"
        case .loadAverage: return "System load"
        case .packages: return "Packages (Homebrew)"
        case .locale: return "Language and region"
        case .hostname: return "Computer name"
        case .username: return "User"
        }
    }

    var icon: String {
        switch self {
        case .os: return "apple.logo"
        case .kernel: return "cpu"
        case .shell: return "terminal"
        case .terminal: return "terminal.fill"
        case .theme: return "circle.lefthalf.filled"
        case .display: return "display"
        case .uptime: return "clock"
        case .cpu: return "cpu.fill"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .host: return "laptopcomputer"
        case .architecture: return "square.stack.3d.up"
        case .gpu: return "square.stack.3d.up.fill"
        case .battery: return "battery.100"
        case .loadAverage: return "gauge.medium"
        case .packages: return "shippingbox"
        case .locale: return "globe"
        case .hostname: return "network"
        case .username: return "person.crop.circle"
        }
    }

    /// The greeting's original ten fields, in their original order — used
    /// both as the factory default and to fill in for configs saved before
    /// this field existed.
    static let defaults: [InfoField] = [
        .os, .kernel, .shell, .terminal, .theme, .display, .uptime, .cpu, .memory, .disk,
    ]
}

/// Native replacement for the fastfetch modules sereno used
/// (os/kernel/shell/terminal/theme/display/uptime/cpu/memory/disk in
/// sereno/fastfetch.jsonc), plus a few extra fields the user can opt into.
/// vidrio already knows its own shell and identity, so those two are cheaper
/// here than they were for fastfetch.
enum SystemInfo {
    struct Line {
        let key: String
        let value: String
    }

    static func lines(shellExecutable: String, fields: [InfoField] = InfoField.defaults) -> [Line] {
        fields.map { Line(key: $0.key, value: value(for: $0, shellExecutable: shellExecutable)) }
    }

    private static func value(for field: InfoField, shellExecutable: String) -> String {
        switch field {
        case .os: return osName()
        case .kernel: return kernelRelease()
        case .shell: return (shellExecutable as NSString).lastPathComponent
        case .terminal: return "vidrio"
        case .theme: return interfaceTheme()
        case .display: return displayInfo()
        case .uptime: return uptime()
        case .cpu: return cpuBrand()
        case .memory: return memoryUsage()
        case .disk: return diskUsage()
        case .host: return hostModel()
        case .architecture: return architecture()
        case .gpu: return gpuName()
        case .battery: return batteryStatus()
        case .loadAverage: return loadAverage()
        case .packages: return packageCount()
        case .locale: return Locale.current.identifier
        case .hostname: return hostname()
        case .username: return ProcessInfo.processInfo.userName
        }
    }

    private static func osName() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var name = "macOS"
        if let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist"),
           let productName = plist["ProductName"] as? String {
            name = productName
        }
        return "\(name) \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }

    private static func kernelRelease() -> String {
        sysctlString("kern.osrelease") ?? "unknown"
    }

    private static func interfaceTheme() -> String {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? "Dark" : "Light"
    }

    private static func displayInfo() -> String {
        let displayID = CGMainDisplayID()
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return "unknown" }
        let refresh = mode.refreshRate
        // Built-in panels commonly report 0Hz through this API — omit rather
        // than print a bogus "@ 0Hz".
        if refresh > 0 {
            return "\(mode.pixelWidth)x\(mode.pixelHeight) @ \(Int(refresh))Hz"
        }
        return "\(mode.pixelWidth)x\(mode.pixelHeight)"
    }

    private static func uptime() -> String {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return "unknown" }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
        let elapsed = Int(Date().timeIntervalSince(bootDate))
        let days = elapsed / 86400
        let hours = (elapsed % 86400) / 3600
        let minutes = (elapsed % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        parts.append("\(minutes)m")
        return parts.joined(separator: " ")
    }

    private static func cpuBrand() -> String {
        sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "unknown"
    }

    private static func memoryUsage() -> String {
        let total = sysctlUInt64("hw.memsize") ?? 0

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return "\(formatBytes(total)) total"
        }
        let pageSize = sysctlUInt64("hw.pagesize") ?? 4096
        let usedPages = UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.compressor_page_count)
        return "\(formatBytes(usedPages * pageSize)) / \(formatBytes(total))"
    }

    private static func diskUsage() -> String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? UInt64,
              let free = attrs[.systemFreeSize] as? UInt64
        else { return "unknown" }
        return "\(formatBytes(total - free)) / \(formatBytes(total))"
    }

    /// Model identifier (e.g. "Mac15,7") — the marketing name isn't exposed
    /// by any local API, so this stays a raw identifier like fastfetch's own.
    private static func hostModel() -> String {
        sysctlString("hw.model") ?? "unknown"
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        return "x86_64 (Intel)"
        #else
        return sysctlString("hw.machine") ?? "unknown"
        #endif
    }

    private static func gpuName() -> String {
        MTLCreateSystemDefaultDevice()?.name ?? "unknown"
    }

    /// Charge percentage and power source, or "unknown" on a desktop Mac.
    private static func batteryStatus() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int
        else { return "unknown" }
        let state = description[kIOPSPowerSourceStateKey] as? String
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let suffix = state == kIOPSACPowerValue ? (charging ? " (charging)" : " (plugged in)") : ""
        return "\(capacity)%\(suffix)"
    }

    private static func loadAverage() -> String {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return "unknown" }
        return averages.map { String(format: "%.2f", $0) }.joined(separator: " ")
    }

    /// Formula + cask count from a local Homebrew install, counted straight
    /// from the Cellar/Caskroom directories — no `brew` subprocess involved.
    private static func packageCount() -> String {
        let prefixes = ["/opt/homebrew", "/usr/local"]
        var formulas = 0, casks = 0
        for prefix in prefixes {
            formulas += subdirectoryCount(at: "\(prefix)/Cellar")
            casks += subdirectoryCount(at: "\(prefix)/Caskroom")
        }
        guard formulas + casks > 0 else { return "unknown" }
        return "\(formulas) formulas, \(casks) casks"
    }

    private static func subdirectoryCount(at path: String) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: path))?.count ?? 0
    }

    private static func hostname() -> String {
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let terminator = buffer.firstIndex(of: 0) { buffer.removeSubrange(terminator...) }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Replaces sereno's `pmset -g batt` shell-out for auto display mode.
    static func isOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSBatteryPowerValue
        }
        return false
    }
}
