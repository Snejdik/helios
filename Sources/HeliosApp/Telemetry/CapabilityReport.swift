import Foundation

struct CapabilityItem: Sendable, Equatable, Identifiable {
    enum State: String, Sendable, Equatable {
        case available = "Available"
        case unavailable = "Unavailable"
        case warming = "Warming up"
    }

    let id: String
    let title: String
    let state: State
    let detail: String
}

struct CapabilityReport: Sendable, Equatable {
    let items: [CapabilityItem]

    var availableCount: Int { items.filter { $0.state == .available }.count }
    var totalCount: Int { items.count }
}

enum CapabilityEvaluator {
    static func evaluate(_ snapshot: TelemetrySnapshot, now: Date = Date()) -> CapabilityReport {
        var items: [CapabilityItem] = []
        func append(_ id: String, _ title: String, _ result: Bool?, _ detail: String) {
            let state: CapabilityItem.State = result == true ? .available : result == false ? .unavailable : .warming
            items.append(CapabilityItem(id: id, title: title, state: state, detail: detail))
        }

        switch TelemetryFormatting.fresh(snapshot.cpu, maxAge: 5, now: now) {
        case .success(let cpu): append("cpu-per-core", "Per-core CPU", !cpu.perCoreUsagePercent.isEmpty, "Mach per-logical-CPU tick deltas")
        case .failure(let e): append("cpu-per-core", "Per-core CPU", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.gpu, maxAge: 5, now: now) {
        case .success(let gpu):
            let available = (try? gpu.deviceUtilizationPercent.get()) != nil
            append("gpu-stats", "GPU PerformanceStatistics", available, "AGX/IOAccelerator read-only statistics")
        case .failure(let e): append("gpu-stats", "GPU PerformanceStatistics", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.systemPower, maxAge: 5, now: now) {
        case .success(let power): append("pstr", "Total system power", (try? power.totalSystemWatts.get()) != nil, "AppleSMC PSTR read-only rail")
        case .failure(let e): append("pstr", "Total system power", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.storage, maxAge: 10, now: now) {
        case .success(let storage): append("nvme-smart", "Native NVMe SMART", (try? storage.smartHealth.get()) != nil, storage.primaryDevice?.smartCapability.rawValue ?? "No primary storage")
        case .failure(let e): append("nvme-smart", "Native NVMe SMART", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.processes, maxAge: 12, now: now) {
        case .success(let processes): append("rusage-v6", "Per-process RUSAGE_INFO_V6", processes.accessibleProcessCount > 0, "\(processes.accessibleProcessCount) accessible processes")
        case .failure(let e): append("rusage-v6", "Per-process RUSAGE_INFO_V6", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.wifi, maxAge: 15, now: now) {
        case .success(let wifi): append("wifi", "CoreWLAN radio", true, "\(wifi.interfaceName) · privacy-safe SSID")
        case .failure(let e): append("wifi", "CoreWLAN radio", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.battery, maxAge: 20, now: now) {
        case .success: append("battery", "AppleSmartBattery", true, "Battery health/power/time telemetry")
        case .failure(let e): append("battery", "AppleSmartBattery", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.thermals, maxAge: 6, now: now) {
        case .success(let thermals): append("smc-thermals", "SMC temperature sensors", !thermals.readings.isEmpty, "\(thermals.readings.count) readable sensors")
        case .failure(let e): append("smc-thermals", "SMC temperature sensors", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.fans, maxAge: 5, now: now) {
        case .success(let fans): append("fans", "Fan telemetry", !fans.fans.isEmpty, "\(fans.fans.count) discovered fan(s); writes remain separately gated")
        case .failure(let e): append("fans", "Fan telemetry", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.fanOwnershipPreflight, maxAge: 15, now: now) {
        case .success(let preflight):
            append("fan-surface", "Fan-control surface match", preflight.isReadyForValidation,
                   "\(preflight.summary); read-only evidence only — production write authorization remains a separate daemon gate")
        case .failure(let e):
            append("fan-surface", "Fan-control surface match", nilIfWarming(e), e.localizedDescription)
        }

        switch TelemetryFormatting.fresh(snapshot.displays, maxAge: 90, now: now) {
        case .success(let value): append("displays", "CoreGraphics displays", true, "\(value.displays.count) online display(s)")
        case .failure(let e): append("displays", "CoreGraphics displays", nilIfWarming(e), e.localizedDescription)
        }
        switch TelemetryFormatting.fresh(snapshot.volumes, maxAge: 90, now: now) {
        case .success(let value): append("volumes", "Mounted volumes", true, "\(value.volumes.count) mounted volume(s)")
        case .failure(let e): append("volumes", "Mounted volumes", nilIfWarming(e), e.localizedDescription)
        }
        switch TelemetryFormatting.fresh(snapshot.usb, maxAge: 150, now: now) {
        case .success(let value): append("usb", "IOKit USB inventory", true, "\(value.devices.count) USB device(s)")
        case .failure(let e): append("usb", "IOKit USB inventory", nilIfWarming(e), e.localizedDescription)
        }
        switch TelemetryFormatting.fresh(snapshot.bluetooth, maxAge: 150, now: now) {
        case .success(let value): append("bluetooth", "Bluetooth inventory", true, "\(value.devices.count) paired device(s); no active scan")
        case .failure(let e): append("bluetooth", "Bluetooth inventory", nilIfWarming(e), e.localizedDescription)
        }
        switch TelemetryFormatting.fresh(snapshot.audio, maxAge: 90, now: now) {
        case .success(let value): append("audio", "CoreAudio devices", true, "\(value.devices.count) audio device(s)")
        case .failure(let e): append("audio", "CoreAudio devices", nilIfWarming(e), e.localizedDescription)
        }
        switch TelemetryFormatting.fresh(snapshot.powerAssertions, maxAge: 45, now: now) {
        case .success(let value): append("power-assertions", "Sleep blockers", true, "\(value.assertions.count) active power assertion(s)")
        case .failure(let e): append("power-assertions", "Sleep blockers", nilIfWarming(e), e.localizedDescription)
        }

        return CapabilityReport(items: items)
    }

    private static func nilIfWarming(_ error: TelemetryError) -> Bool? {
        error == .warmingUp ? nil : false
    }
}
