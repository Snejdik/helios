import CoreWLAN
import Foundation

struct WiFiMetrics: Sendable {
    let interfaceName: String
    let powerOn: Bool
    let serviceActive: Bool
    let ssid: MetricResult<String>
    let rssiDBm: MetricResult<Int>
    let noiseDBm: MetricResult<Int>
    let transmitRateMbps: MetricResult<Double>
    let transmitPowerMilliwatts: MetricResult<Int>
    let channelNumber: MetricResult<Int>
    let channelBand: MetricResult<String>
    let channelWidth: MetricResult<String>
    let phyMode: MetricResult<String>
    let security: MetricResult<String>

    var signalToNoiseDB: MetricResult<Int> {
        captureMetric {
            let rssi = try rssiDBm.get()
            let noise = try noiseDBm.get()
            let value = rssi - noise
            guard (-20...100).contains(value) else { throw TelemetryError.invalidData("Wi-Fi SNR outside plausible range") }
            return value
        }
    }
}

enum WiFiFormatting {
    static func band(rawValue: Int) -> String {
        switch rawValue {
        case 1: return "2.4 GHz"
        case 2: return "5 GHz"
        case 3: return "6 GHz"
        case Int.max: return "Unknown"
        default: return "Band \(rawValue)"
        }
    }

    static func width(rawValue: Int) -> String {
        switch rawValue {
        case 1: return "20 MHz"
        case 2: return "40 MHz"
        case 3: return "80 MHz"
        case 4: return "160 MHz"
        case Int.max: return "Unknown"
        default: return "Width \(rawValue)"
        }
    }

    static func phy(rawValue: Int) -> String {
        switch rawValue {
        case 0: return "None"
        case 1: return "802.11a"
        case 2: return "802.11b"
        case 3: return "802.11g"
        case 4: return "802.11n / Wi-Fi 4"
        case 5: return "802.11ac / Wi-Fi 5"
        case 6: return "802.11ax / Wi-Fi 6/6E"
        case 7: return "802.11be / Wi-Fi 7"
        default: return "PHY \(rawValue)"
        }
    }

    /// CWSecurity raw values are stable public CoreWLAN ABI. Keep this raw-value
    /// mapping instead of switching on newer enum cases so the app can still
    /// deploy to macOS 13 while being built with a newer SDK.
    static func security(rawValue: Int) -> String {
        switch rawValue {
        case 0: return "None"
        case 1: return "WEP"
        case 2: return "WPA Personal"
        case 3: return "WPA/WPA2 Personal"
        case 4: return "WPA2 Personal"
        case 5: return "Personal"
        case 6: return "Dynamic WEP"
        case 7: return "WPA Enterprise"
        case 8: return "WPA/WPA2 Enterprise"
        case 9: return "WPA2 Enterprise"
        case 10: return "Enterprise"
        case 11: return "WPA3 Personal"
        case 12: return "WPA3 Enterprise"
        case 13: return "WPA3 Transition"
        case 14: return "OWE"
        case 15: return "OWE Transition"
        case Int.max: return "Unknown"
        default: return "Security \(rawValue)"
        }
    }
}

actor WiFiProvider {
    private let client = CWWiFiClient.shared()

    func reset() {}

    func sample() -> MetricSample<WiFiMetrics> {
        MetricSample(captureMetric { try read() })
    }

    private func read() throws -> WiFiMetrics {
        guard let interface = client.interface() else {
            throw TelemetryError.unavailable("Wi-Fi interface unavailable")
        }
        let name = interface.interfaceName ?? "Wi-Fi"
        let powerOn = interface.powerOn()
        let serviceActive = interface.serviceActive()

        let ssid: MetricResult<String>
        if let value = interface.ssid(), !value.isEmpty {
            ssid = .success(value)
        } else {
            ssid = .failure(.unavailable("SSID hidden by macOS privacy or not associated"))
        }

        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        let rate = interface.transmitRate()
        let transmitPower = interface.transmitPower()
        let channel = interface.wlanChannel()

        return WiFiMetrics(
            interfaceName: name,
            powerOn: powerOn,
            serviceActive: serviceActive,
            ssid: ssid,
            rssiDBm: serviceActive && rssi != 0 ? .success(rssi) : .failure(.unavailable("Wi-Fi RSSI unavailable")),
            noiseDBm: serviceActive && noise != 0 ? .success(noise) : .failure(.unavailable("Wi-Fi noise unavailable")),
            transmitRateMbps: serviceActive && rate > 0 && rate.isFinite ? .success(rate) : .failure(.unavailable("Wi-Fi transmit rate unavailable")),
            transmitPowerMilliwatts: powerOn && transmitPower > 0 ? .success(transmitPower) : .failure(.unavailable("Wi-Fi transmit power unavailable")),
            channelNumber: channel.map { .success($0.channelNumber) } ?? .failure(.unavailable("Wi-Fi channel unavailable")),
            channelBand: channel.map { .success(WiFiFormatting.band(rawValue: Int($0.channelBand.rawValue))) } ?? .failure(.unavailable("Wi-Fi band unavailable")),
            channelWidth: channel.map { .success(WiFiFormatting.width(rawValue: Int($0.channelWidth.rawValue))) } ?? .failure(.unavailable("Wi-Fi channel width unavailable")),
            phyMode: serviceActive ? .success(WiFiFormatting.phy(rawValue: Int(interface.activePHYMode().rawValue))) : .failure(.unavailable("Wi-Fi PHY mode unavailable")),
            security: serviceActive ? .success(WiFiFormatting.security(rawValue: Int(interface.security().rawValue))) : .failure(.unavailable("Wi-Fi security unavailable"))
        )
    }
}
