import SwiftUI

struct HeliosNetworkPage: View {
  let context: HeliosContext
  @ObservedObject var model: OverviewViewModel
  @State private var showDetails = false

  var body: some View {
    let presentation = model.presentation
    VStack(alignment: .leading, spacing: HeliosDesign.sectionSpacing) {
      if !context.preferences.isTelemetryCollectionRequired(.network) {
        HeliosCollectionOffNotice(
          title: "Network monitoring is off.", module: .network, preferences: context.preferences)
      } else {
        header(presentation.network)
        HeliosChartPanel(
          metric: .network, model: model, preferences: context.preferences, scope: .network)
        HeliosChartPanel(
          metric: .networkUpload, model: model, preferences: context.preferences, scope: .network,
          height: 110, showsRange: false)
        if case .success(let network) = presentation.network {
          HStack(alignment: .top, spacing: 20) {
            HeliosSection("Connection") { HeliosGroup { connectionRows(network) } }
            HeliosSection("Wi-Fi") { wifi(presentation.wifi) }
          }
          HeliosSection("Addresses") { HeliosGroup { addressRows(network) } }
          DisclosureGroup("Details", isExpanded: $showDetails) {
            HeliosFactList(rows: detailRows(network)).padding(.top, 8)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func header(_ result: MetricResult<NetworkMetrics>) -> some View {
    switch result {
    case .success(let network):
      let connected = (try? network.isRunning.get()) == true
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          HeliosStatusLabel(status: connected ? .normal : .unavailable, prominent: true)
          Text(connected
            ? "Connected via \(HeliosText.value(network.primaryInterface) { $0 })."
            : "No active network connection.")
            .foregroundStyle(.secondary)
        }
        Spacer()
        if case .success(let rate) = network.throughput {
          HStack(spacing: 24) {
            HeliosHeadlineValue(value: TelemetryFormatting.bytesPerSecond(rate.downloadBytesPerSecond), caption: "Download")
            HeliosHeadlineValue(value: TelemetryFormatting.bytesPerSecond(rate.uploadBytesPerSecond), caption: "Upload")
          }
        }
      }
    case .failure(let error):
      HeliosStatusLabel(status: error == .warmingUp ? .waiting : .unavailable, prominent: true)
    }
  }

  @ViewBuilder
  private func connectionRows(_ network: NetworkMetrics) -> some View {
    HeliosFactRow(label: "Interface", value: HeliosText.value(network.primaryInterface) { $0 })
    HeliosFactRow(label: "Link speed",
      value: HeliosText.value(network.linkSpeedBitsPerSecond) { TelemetryFormatting.bitsPerSecond($0) })
    HeliosFactRow(label: "Downloaded this session",
      value: HeliosText.value(network.sessionDownloadedBytes) { TelemetryFormatting.storageBytes($0) })
    HeliosFactRow(label: "Uploaded this session",
      value: HeliosText.value(network.sessionUploadedBytes) { TelemetryFormatting.storageBytes($0) },
      showsDivider: false)
  }

  @ViewBuilder
  private func wifi(_ result: MetricResult<WiFiMetrics>) -> some View {
    if !context.preferences.isTelemetryCollectionRequired(.wifi) {
      HeliosCollectionOffNotice(title: "Wi-Fi details are off.", module: .wifi, preferences: context.preferences)
    } else {
      switch result {
      case .success(let wifi):
        HeliosGroup {
          HeliosFactRow(label: "Signal", value: HeliosText.value(wifi.rssiDBm) { "\($0) dBm" },
            detail: HeliosText.value(wifi.signalToNoiseDB) { "SNR \($0) dB" })
          HeliosFactRow(label: "Transmit rate",
            value: HeliosText.value(wifi.transmitRateMbps) { String(format: "%.0f Mb/s", $0) })
          HeliosFactRow(label: "Channel",
            value: "\(HeliosText.value(wifi.channelNumber) { "\($0)" }) · \(HeliosText.value(wifi.channelBand) { $0 })")
          HeliosFactRow(label: "Security", value: HeliosText.value(wifi.security) { $0 }, showsDivider: false)
        }
      case .failure(let error):
        Text("Wi-Fi: \(HeliosText.failure(error))").foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func addressRows(_ network: NetworkMetrics) -> some View {
    HeliosFactRow(label: "IPv4 address", value: HeliosText.value(network.ipv4Address) { $0 })
    HeliosFactRow(label: "IPv6 address", value: HeliosText.value(network.ipv6Address) { $0 })
    HeliosFactRow(label: "Router", value: HeliosText.value(network.gatewayIPv4) { $0 },
      showsDivider: !network.dnsServers.isEmpty)
    if !network.dnsServers.isEmpty {
      HeliosFactRow(label: "DNS", value: network.dnsServers.joined(separator: ", "), showsDivider: false)
    }
  }

  private func detailRows(_ network: NetworkMetrics) -> [HeliosEvidence] {
    var rows = [
      HeliosEvidence(label: "MTU", value: HeliosText.value(network.mtu) { "\($0)" }),
      HeliosEvidence(label: "Errors (in / out)",
        value: "\(HeliosText.value(network.receiveErrors) { "\($0)" }) / \(HeliosText.value(network.transmitErrors) { "\($0)" })"),
      HeliosEvidence(label: "Active interfaces", value: network.activeInterfaces.joined(separator: ", ")),
    ]
    if !network.searchDomains.isEmpty {
      rows.append(HeliosEvidence(label: "Search domains", value: network.searchDomains.joined(separator: ", ")))
    }
    return rows
  }
}
