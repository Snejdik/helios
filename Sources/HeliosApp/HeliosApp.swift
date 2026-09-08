import AppKit

@main
@MainActor
enum HeliosApp {
    static func main() {
#if DEBUG
        if CommandLine.arguments.contains("--fan-preflight") {
            do {
                let snapshot = try SMCFanOwnershipPreflightReader().read()
                print(snapshot.diagnosticText)
                exit(snapshot.isReadyForValidation ? 0 : 2)
            } catch {
                print("Fan ownership preflight failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--storage-preflight") {
            do {
                let snapshot = try IOKitStorageReader().readWithSMARTProbe()
                print(snapshot.diagnosticText)
                exit(snapshot.devices.isEmpty ? 2 : 0)
            } catch {
                print("Storage preflight failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        if CommandLine.arguments.contains("--performance-preflight") {
            Task { @MainActor in
                let gpu = GPUProvider()
                let power = SystemPowerProvider()
                let memory = MemoryProvider()
                let battery = BatteryProvider()
                async let gpuSample = gpu.sample()
                async let powerSample = power.sample()
                async let memorySample = memory.sample()
                async let batterySample = battery.sample()
                let (g, p, m, b) = await (gpuSample, powerSample, memorySample, batterySample)
                print("Performance preflight (read-only)")
                switch g.result {
                case .success(let value):
                    print("GPU: " + TelemetryFormatting.text(value.model) { $0 })
                    print("  cores=" + TelemetryFormatting.text(value.coreCount) { String($0) })
                    let deviceUsage = TelemetryFormatting.text(value.deviceUtilizationPercent, format: { String(format: "%.1f%%", $0) })
                    let rendererUsage = TelemetryFormatting.text(value.rendererUtilizationPercent, format: { String(format: "%.1f%%", $0) })
                    let tilerUsage = TelemetryFormatting.text(value.tilerUtilizationPercent, format: { String(format: "%.1f%%", $0) })
                    print("  utilization=\(deviceUsage) renderer=\(rendererUsage) tiler=\(tilerUsage)")
                    print("  memory mapped=" + TelemetryFormatting.text(value.allocatedSystemMemoryBytes, format: TelemetryFormatting.storageBytes) +
                          " in-use=" + TelemetryFormatting.text(value.inUseSystemMemoryBytes, format: TelemetryFormatting.storageBytes))
                case .failure(let error):
                    print("GPU: unavailable — \(error.localizedDescription)")
                }
                switch p.result.flatMap(\.totalSystemWatts) {
                case .success(let watts): print(String(format: "Total System Power (PSTR): %.2f W", watts))
                case .failure(let error): print("Total System Power: unavailable — \(error.localizedDescription)")
                }
                switch m.result {
                case .success(let value):
                    print("Swap: used=" + TelemetryFormatting.text(value.swapUsedBytes, format: TelemetryFormatting.storageBytes) +
                          " total=" + TelemetryFormatting.text(value.swapTotalBytes, format: TelemetryFormatting.storageBytes))
                case .failure(let error): print("Memory: unavailable — \(error.localizedDescription)")
                }
                switch b.result {
                case .success(let value):
                    let charge = TelemetryFormatting.text(value.stateOfChargePercent, format: { String(format: "%.1f%%", $0) })
                    let voltage = TelemetryFormatting.text(value.voltageVolts, format: { String(format: "%.2f V", $0) })
                    let current = TelemetryFormatting.text(value.currentAmps, format: { String(format: "%+.2f A", $0) })
                    let adapter = TelemetryFormatting.text(value.adapterWatts, format: { "\($0) W" })
                    let charging = TelemetryFormatting.text(value.isCharging, format: { $0 ? "yes" : "no" })
                    let source = TelemetryFormatting.text(value.powerSource, format: { $0.rawValue })
                    print("Battery: charge=\(charge) voltage=\(voltage) current=\(current) source=\(source) charging=\(charging) adapter=\(adapter)")
                case .failure(let error): print("Battery: unavailable — \(error.localizedDescription)")
                }
                print("No fan writes, subprocesses, or privileged telemetry are used by this probe.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--utility-preflight") {
            Task { @MainActor in
                let network = NetworkProvider()
                let system = SystemProvider()
                let battery = BatteryProvider()
                _ = await network.sample() // warm the counter-delta provider
                try? await Task.sleep(for: .seconds(1))
                async let networkSample = network.sample()
                async let systemSample = system.sample()
                async let batterySample = battery.sample()
                let (n, s, b) = await (networkSample, systemSample, batterySample)
                print("Utility preflight (read-only)")
                switch s.result {
                case .success(let value):
                    let model = TelemetryFormatting.text(value.modelIdentifier) { $0 }
                    let chip = TelemetryFormatting.text(value.chipName) { $0 }
                    print("System: \(model) / \(chip)")
                    print("  OS=\(value.osVersion) uptime=\(TelemetryFormatting.duration(value.uptimeSeconds)) CPUs=\(value.logicalProcessorCount) memory=\(TelemetryFormatting.storageBytes(value.physicalMemoryBytes))")
                    print("  thermal=\(value.thermalState.rawValue) lowPower=\(value.lowPowerModeEnabled ? "on" : "off")")
                    print("  load 1/5/15=" + TelemetryFormatting.text(value.loadAverage1) { String(format: "%.2f", $0) } + "/" + TelemetryFormatting.text(value.loadAverage5) { String(format: "%.2f", $0) } + "/" + TelemetryFormatting.text(value.loadAverage15) { String(format: "%.2f", $0) })
                case .failure(let error): print("System: unavailable — \(error.localizedDescription)")
                }
                switch n.result {
                case .success(let value):
                    let primary = TelemetryFormatting.text(value.primaryInterface) { $0 }
                    let ipv4 = TelemetryFormatting.text(value.ipv4Address) { $0 }
                    let ipv6 = TelemetryFormatting.text(value.ipv6Address) { $0 }
                    print("Network: primary=\(primary) active=\(value.activeInterfaceCount) IPv4=\(ipv4) IPv6=\(ipv6)")
                    switch value.throughput {
                    case .success(let rate):
                        print("  download=\(TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond)) upload=\(TelemetryFormatting.bytesPerSecond(rate.uploadBytesPerSecond)) rx=\(TelemetryFormatting.iops(rate.receivePacketsPerSecond)) pkt/s tx=\(TelemetryFormatting.iops(rate.transmitPacketsPerSecond)) pkt/s")
                    case .failure(let error): print("  throughput=unavailable — \(error.localizedDescription)")
                    }
                    print("  link=" + TelemetryFormatting.text(value.linkSpeedBitsPerSecond, format: TelemetryFormatting.bitsPerSecond) +
                          " MTU=" + TelemetryFormatting.text(value.mtu) { String($0) } +
                          " RXerr=" + TelemetryFormatting.text(value.receiveErrors) { String($0) } +
                          " TXerr=" + TelemetryFormatting.text(value.transmitErrors) { String($0) })
                case .failure(let error): print("Network: unavailable — \(error.localizedDescription)")
                }
                switch b.result {
                case .success(let value):
                    print("Battery time remaining: " + TelemetryFormatting.text(value.timeRemaining, format: TelemetryFormatting.batteryTimeRemaining))
                case .failure(let error): print("Battery: unavailable — \(error.localizedDescription)")
                }
                print("History/energy integration is deterministic and covered by the regression suite; this probe performs no writes, subprocesses, or privileged telemetry.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--observability-preflight") {
            Task { @MainActor in
                let cpu = CPUProvider()
                let wifi = WiFiProvider()
                let processes = ProcessProvider()

                _ = await cpu.sample()
                _ = await processes.sample()
                try? await Task.sleep(for: .seconds(1))

                async let cpuSample = cpu.sample()
                async let wifiSample = wifi.sample()
                async let processSample = processes.sample()
                let (c, w, p) = await (cpuSample, wifiSample, processSample)

                print("Observability preflight (read-only)")
                switch c.result {
                case .success(let value):
                    print(String(format: "CPU: %.1f%% across %d logical cores", value.usagePercent, value.perCoreUsagePercent.count))
                    if !value.perCoreUsagePercent.isEmpty {
                        let cores = value.perCoreUsagePercent.enumerated()
                            .map { String(format: "C%d=%.0f%%", $0.offset + 1, $0.element) }
                            .joined(separator: " ")
                        print("  \(cores)")
                    }
                case .failure(let error):
                    print("CPU: unavailable — \(error.localizedDescription)")
                }

                switch w.result {
                case .success(let value):
                    let ssid = TelemetryFormatting.text(value.ssid) { $0 }
                    let rssi = TelemetryFormatting.text(value.rssiDBm) { "\($0) dBm" }
                    let noise = TelemetryFormatting.text(value.noiseDBm) { "\($0) dBm" }
                    let snr = TelemetryFormatting.text(value.signalToNoiseDB) { "\($0) dB" }
                    let rate = TelemetryFormatting.text(value.transmitRateMbps) { String(format: "%.0f Mb/s", $0) }
                    let txPower = TelemetryFormatting.text(value.transmitPowerMilliwatts) { "\($0) mW" }
                    let channel = TelemetryFormatting.text(value.channelNumber) { String($0) }
                    let band = TelemetryFormatting.text(value.channelBand) { $0 }
                    let width = TelemetryFormatting.text(value.channelWidth) { $0 }
                    let phy = TelemetryFormatting.text(value.phyMode) { $0 }
                    let security = TelemetryFormatting.text(value.security) { $0 }
                    print("Wi-Fi: interface=\(value.interfaceName) power=\(value.powerOn ? "on" : "off") service=\(value.serviceActive ? "active" : "inactive") SSID=\(ssid)")
                    print("  RSSI=\(rssi) noise=\(noise) SNR=\(snr) TX=\(rate) power=\(txPower)")
                    print("  channel=\(channel) band=\(band) width=\(width) PHY=\(phy) security=\(security)")
                case .failure(let error):
                    print("Wi-Fi: unavailable — \(error.localizedDescription)")
                }

                switch p.result {
                case .success(let value):
                    print("Processes: accessible=\(value.accessibleProcessCount)")
                    for process in value.topByCPU.prefix(5) {
                        let cpu = process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "warming"
                        let power = process.powerWatts.map { String(format: "%.3f W direct", $0) } ?? "warming"
                        let pPower = process.performanceCorePowerWatts.map { String(format: "%.3f W P-core", $0) } ?? "warming"
                        let ipc = process.instructionsPerCycle.map { String(format: "%.2f", $0) } ?? "—"
                        print("  pid=\(process.pid) \(process.name): CPU=\(cpu) energy=\(power) \(pPower) memory=\(TelemetryFormatting.storageBytes(process.physicalFootprintBytes)) ANE=\(TelemetryFormatting.storageBytes(process.neuralFootprintBytes)) IPC=\(ipc)")
                    }
                case .failure(let error):
                    print("Processes: unavailable — \(error.localizedDescription)")
                }

                print("No fan writes, notification prompts, history writes, subprocesses, or privileged telemetry are used by this probe.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--io-preflight") {
            Task { @MainActor in
                let storage = StorageProvider()
                let processes = ProcessProvider()
                let network = NetworkProvider()
                let system = SystemProvider()

                // Warm every delta-based provider first. The second sample is the
                // read-only evidence window; no persistent audit/history files are written.
                _ = await storage.sample()
                _ = await processes.sample()
                _ = await network.sample()
                try? await Task.sleep(for: .seconds(2))

                async let storageSample = storage.sample()
                async let processSample = processes.sample()
                async let networkSample = network.sample()
                async let systemSample = system.sample()
                let (st, pr, nw, sy) = await (storageSample, processSample, networkSample, systemSample)

                print("I/O attribution preflight (read-only)")
                var uptime: TimeInterval?
                if case .success(let value) = sy.result { uptime = value.uptimeSeconds }

                switch st.result {
                case .success(let value):
                    print("Storage: primary=\(value.primaryDeviceBSDName ?? "none")")
                    if let primary = value.primaryDevice, case .success(let counters) = primary.counters {
                        print("  physical since boot: read=\(TelemetryFormatting.storageBytes(counters.bytesRead)) written=\(TelemetryFormatting.storageBytes(counters.bytesWritten))")
                        if let uptime, uptime > 0 {
                            print("  boot-average: read=\(TelemetryFormatting.bytesPerSecond(Double(counters.bytesRead) / uptime)) written=\(TelemetryFormatting.bytesPerSecond(Double(counters.bytesWritten) / uptime))")
                        }
                    }
                    switch value.throughput {
                    case .success(let rate):
                        print("  physical current: read=\(TelemetryFormatting.bytesPerSecond(rate.readBytesPerSecond)) write=\(TelemetryFormatting.bytesPerSecond(rate.writeBytesPerSecond))")
                    case .failure(let error): print("  physical current: unavailable — \(error.localizedDescription)")
                    }
                    print("  since preflight start: read=" + TelemetryFormatting.text(value.monitoringReadBytes, format: TelemetryFormatting.storageBytes) +
                          " written=" + TelemetryFormatting.text(value.monitoringWrittenBytes, format: TelemetryFormatting.storageBytes))
                case .failure(let error): print("Storage: unavailable — \(error.localizedDescription)")
                }

                switch pr.result {
                case .success(let value):
                    print("Processes: accessible=\(value.accessibleProcessCount)")
                    print("  accounted current: read=\(TelemetryFormatting.bytesPerSecond(value.accountedDiskReadBytesPerSecond)) write=\(TelemetryFormatting.bytesPerSecond(value.accountedDiskWriteBytesPerSecond))")
                    print("  accounted since preflight start: read=\(TelemetryFormatting.storageBytes(value.sessionAccountedReadBytes)) written=\(TelemetryFormatting.storageBytes(value.sessionAccountedWriteBytes))")
                    if let reader = value.topByDiskRead.first, let rate = reader.diskReadBytesPerSecond {
                        print("  top reader: pid=\(reader.pid) \(reader.name) \(TelemetryFormatting.bytesPerSecond(rate))")
                    }
                    if let writer = value.topByDiskWrite.first, let rate = writer.diskWriteBytesPerSecond {
                        print("  top writer: pid=\(writer.pid) \(writer.name) \(TelemetryFormatting.bytesPerSecond(rate))")
                    }
                    if let helios = value.heliosActivity {
                        let read = helios.diskReadBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "warming"
                        let write = helios.diskWriteBytesPerSecond.map(TelemetryFormatting.bytesPerSecond) ?? "warming"
                        print("  Helios itself: CPU=\(helios.cpuPercent.map { String(format: "%.2f%%", $0) } ?? "warming") read=\(read) write=\(write) memory=\(TelemetryFormatting.storageBytes(helios.physicalFootprintBytes))")
                    }
                case .failure(let error): print("Processes: unavailable — \(error.localizedDescription)")
                }

                switch nw.result {
                case .success(let value):
                    print("Network session: down=" + TelemetryFormatting.text(value.sessionDownloadedBytes, format: TelemetryFormatting.storageBytes) +
                          " up=" + TelemetryFormatting.text(value.sessionUploadedBytes, format: TelemetryFormatting.storageBytes))
                case .failure(let error): print("Network: unavailable — \(error.localizedDescription)")
                }

                print("Physical storage counters include all macOS/APFS/VM/cache/kernel I/O. libproc process accounting is a different layer and is not expected to sum exactly to physical device bytes.")
                print("No fan writes, persistent history/audit writes, subprocesses, notification prompts, or privileged telemetry are used by this probe.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--feature-preflight") {
            Task { @MainActor in
                let cpu = CPUProvider()
                let memory = MemoryProvider()
                let battery = BatteryProvider()
                let displays = DisplayProvider()
                let volumes = VolumeProvider()
                let usb = USBProvider()
                let bluetooth = BluetoothProvider()
                let audio = AudioProvider()
                let assertions = PowerAssertionsProvider()
                let clock = ClockProvider()

                _ = await cpu.sample()
                try? await Task.sleep(for: .seconds(1))
                async let cpuSample = cpu.sample()
                async let memorySample = memory.sample()
                async let batterySample = battery.sample()
                async let displaySample = displays.sample()
                async let volumeSample = volumes.sample()
                async let usbSample = usb.sample()
                async let bluetoothSample = bluetooth.sample()
                async let audioSample = audio.sample()
                async let assertionSample = assertions.sample()
                async let clockSample = clock.sample()
                let (c, m, b, d, v, u, bt, a, pa, cl) = await (
                    cpuSample, memorySample, batterySample, displaySample, volumeSample,
                    usbSample, bluetoothSample, audioSample, assertionSample, clockSample
                )

                print("Next22 feature preflight (read-only)")
                switch c.result {
                case .success(let value):
                    print(String(format: "CPU: %.1f%% logical=%d physical=%@ P=%@ E=%@",
                                 value.usagePercent, value.perCoreUsagePercent.count,
                                 TelemetryFormatting.text(value.physicalCoreCount) { String($0) },
                                 TelemetryFormatting.text(value.performanceCoreCount) { String($0) },
                                 TelemetryFormatting.text(value.efficiencyCoreCount) { String($0) }))
                case .failure(let error): print("CPU: unavailable — \(error.localizedDescription)")
                }
                switch m.result {
                case .success(let value):
                    print("Memory: used=\(TelemetryFormatting.storageBytes(value.usedBytes)) app=\(TelemetryFormatting.storageBytes(value.appBytes)) cache=\(TelemetryFormatting.storageBytes(value.cacheBytes)) available=\(TelemetryFormatting.storageBytes(value.availableBytes))")
                    print("  pressure=" + TelemetryFormatting.text(value.pressure) { $0.rawValue } +
                          " swap=" + TelemetryFormatting.text(value.swapUsedBytes, format: TelemetryFormatting.storageBytes) +
                          " in/out=\(value.swapIns)/\(value.swapOuts)")
                case .failure(let error): print("Memory: unavailable — \(error.localizedDescription)")
                }
                switch b.result {
                case .success(let value):
                    let systemSoC = TelemetryFormatting.text(value.systemChargePercent) { String(format: "%.1f%%", $0) }
                    let rawSoC = TelemetryFormatting.text(value.rawStateOfChargePercent) { String(format: "%.1f%%", $0) }
                    let health = TelemetryFormatting.text(value.healthPercent) { String(format: "%.1f%%", $0) }
                    let optimized = TelemetryFormatting.text(value.optimizedChargingEngaged) { $0 ? "engaged" : "not engaged" }
                    print("Battery: systemSoC=\(systemSoC) rawSoC=\(rawSoC) health=\(health) optimized=\(optimized)")
                    print("  raw current=" + TelemetryFormatting.text(value.currentCapacityMAh) { "\($0) mAh" } +
                          " full=" + TelemetryFormatting.text(value.maximumCapacityMAh) { "\($0) mAh" })
                case .failure(let error): print("Battery: unavailable — \(error.localizedDescription)")
                }
                switch d.result {
                case .success(let value):
                    print("Displays: \(value.displays.count)")
                    for item in value.displays.prefix(4) {
                        let rate = item.refreshRateHz.map { String(format: " @ %.0f Hz", $0) } ?? ""
                        print("  \(item.label): \(item.pixelWidth)x\(item.pixelHeight) px / \(item.logicalWidth)x\(item.logicalHeight) logical\(rate)")
                    }
                case .failure(let error): print("Displays: unavailable — \(error.localizedDescription)")
                }
                switch v.result {
                case .success(let value): print("Mounted volumes: \(value.volumes.count) (external/removable=\(value.volumes.filter { $0.isRemovable == true || $0.isInternal == false }.count))")
                case .failure(let error): print("Mounted volumes: unavailable — \(error.localizedDescription)")
                }
                switch u.result {
                case .success(let value): print("USB devices: \(value.devices.count)")
                case .failure(let error): print("USB: unavailable — \(error.localizedDescription)")
                }
                switch bt.result {
                case .success(let value):
                    print("Bluetooth: paired=\(value.devices.count) connected=\(value.devices.filter(\.connected).count) (no active scan)")
                    for device in value.devices.filter(\.connected).prefix(4) {
                        let battery = device.battery.mainPercent.map { " battery=\($0)%" } ?? ""
                        print("  \(device.name) RSSI=\(device.rssiDBm.map(String.init) ?? "—") dBm\(battery)")
                    }
                case .failure(let error): print("Bluetooth: unavailable — \(error.localizedDescription)")
                }
                switch a.result {
                case .success(let value):
                    let inputSummary = value.inputTelemetrySuppressedForPrivacy ? "not probed (privacy-safe)" : (value.defaultInput?.name ?? "—")
                    print("Audio: devices=\(value.devices.count) input=\(inputSummary) output=\(value.defaultOutput?.name ?? "—")")
                case .failure(let error): print("Audio: unavailable — \(error.localizedDescription)")
                }
                switch pa.result {
                case .success(let value): print("Sleep blockers: assertions=\(value.assertions.count) display=\(value.displaySleepBlockers.count) system=\(value.systemSleepBlockers.count)")
                case .failure(let error): print("Sleep blockers: unavailable — \(error.localizedDescription)")
                }
                if case .success(let value) = cl.result {
                    print("Clock: zone=\(value.localTimeZoneIdentifier) ISO-week=\(value.isoWeekOfYear) day-of-year=\(value.dayOfYear)")
                }
                print("Battery telemetry is read-only; charging policy remains owned by macOS and Helios exposes no battery-control write path.")
                print("No fan writes, persistent writes, subprocesses, active Bluetooth scans, notification prompts, or privileged telemetry are used by this probe.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--smc-inventory-preflight") {
            Task { @MainActor in
                let provider = SMCNumericProvider()
                let sample = await provider.sample(maximumReadings: 512)
                print("Expert SMC numeric inventory preflight (read-only, on-demand)")
                switch sample.result {
                case .success(let value):
                    print("Numeric channels: \(value.readings.count)\(value.truncated ? " (truncated)" : "") failures=\(value.failures.count)")
                    for reading in value.readings.prefix(40) {
                        print(String(format: "  %@ type='%@' raw=%.6g", reading.key, reading.type, reading.value))
                    }
                case .failure(let error):
                    print("SMC numeric inventory unavailable — \(error.localizedDescription)")
                }
                print("Values are intentionally unitless unless a dedicated Helios provider has validated their meaning. Unknown keys never enter fan safety.")
                print("No fan writes, battery-control writes, persistent writes, subprocesses, notification prompts, or privileged telemetry are used by this probe.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--maintenance-preflight") {
            Task { @MainActor in
                let cleanup = CleanupProvider()
                let applications = ApplicationsProvider()
                async let cleanupSample = cleanup.sample()
                async let appSample = applications.sample()
                let (c, a) = await (cleanupSample, appSample)
                print("Maintenance inventory preflight (read-only, on-demand)")
                if case .success(let value) = c.result {
                    print("Cleanup scout: \(TelemetryFormatting.storageBytes(value.estimatedBytes)) across \(value.candidates.count) known cache/developer locations")
                    for item in value.candidates { print("  \(item.label): \(TelemetryFormatting.storageBytes(item.estimatedBytes)) entries=\(item.scannedEntries)\(item.truncated ? " truncated" : "")") }
                }
                if case .success(let value) = a.result {
                    let arm = value.applications.filter { $0.architecture == .appleSilicon }.count
                    let intel = value.applications.filter { $0.architecture == .intel }.count
                    let universal = value.applications.filter { $0.architecture == .universal }.count
                    let measured = value.applications.compactMap(\.estimatedSizeBytes).reduce(UInt64(0)) { lhs, rhs in
                        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
                        return overflow ? UInt64.max : sum
                    }
                    let incomplete = value.applications.filter(\.sizeTruncated).count
                    print("Applications: \(value.applications.count) AppleSilicon=\(arm) Universal=\(universal) Intel=\(intel) observedSize=\(TelemetryFormatting.storageBytes(measured)) incompleteSizeScans=\(incomplete)")
                    for app in value.applications.sorted(by: { ($0.estimatedSizeBytes ?? 0) > ($1.estimatedSizeBytes ?? 0) }).prefix(8) {
                        let size = app.estimatedSizeBytes.map(TelemetryFormatting.storageBytes) ?? "unmeasured"
                        print("  \(app.name): \(size) · \(app.architecture.rawValue)\(app.sizeTruncated ? " · partial" : "")")
                    }
                }
                print("This on-demand probe may read application bundles/cache metadata, but never deletes or modifies anything and launches no subprocesses.")
                exit(0)
            }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--verify-installed-xpc") {
            Task { @MainActor in exit(await DaemonRegistrationProbe.verifyConnection()) }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--unregister-helper") || CommandLine.arguments.contains("--reinstall-helper") {
            Task { @MainActor in exit(await DaemonRegistrationProbe.manage(reinstall: CommandLine.arguments.contains("--reinstall-helper"))) }
            RunLoop.current.run()
            return
        }
        if CommandLine.arguments.contains("--verify-service-lifecycle") {
            Task { @MainActor in exit(await DaemonRegistrationProbe.run()) }
            RunLoop.current.run()
            return
        }
#endif
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var telemetry: TelemetryMonitor?
    private var service: DaemonService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let service = DaemonService()
        self.service = service
        service.start()
        let controller = StatusItemController(service: service)
        let monitor = TelemetryMonitor()
        monitor.onChange = { [weak controller, weak service] snapshot in
            service?.fanControl.refresh(snapshot)
            controller?.update(snapshot)
        }
        monitor.onThermalSample = { [weak service, weak monitor] sample in
            service?.fanControl.accept(sample)
            monitor?.thermalInterval = service?.fanControl.pollingInterval ?? .seconds(2)
        }
        statusItemController = controller
        telemetry = monitor
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        telemetry?.shutdown()
        service?.shutdown()
    }
}
