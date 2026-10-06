import AppKit
import SwiftUI

/// Shared metrics for the Helios interface. Native text styles only; the
/// smallest text used anywhere is `.subheadline` (11 pt on macOS).
enum HeliosDesign {
  static let pagePadding: CGFloat = 24
  static let sectionSpacing: CGFloat = 22
  static let groupCornerRadius: CGFloat = 10
  static let maxContentWidth: CGFloat = 980
  /// Settings column: centred like the main window's pages, narrower for forms.
  static let settingsContentWidth: CGFloat = 720
  static let statusChange = Animation.easeInOut(duration: 0.2)

  static func color(_ status: HeliosStatus) -> Color {
    switch status {
    case .good, .normal: .green
    case .attention: .orange
    case .critical: .red
    case .waiting, .stale, .unavailable, .notPresent: .secondary
    }
  }

  static func symbol(_ status: HeliosStatus) -> String {
    switch status {
    case .good, .normal: "circle.fill"
    case .attention: "exclamationmark.triangle.fill"
    case .critical: "exclamationmark.octagon.fill"
    case .waiting: "circle.dotted"
    case .stale: "clock"
    case .unavailable: "minus.circle"
    case .notPresent: "circle.slash"
    }
  }

  static func toneColor(_ tone: HeliosActivityEvent.Tone) -> Color {
    switch tone {
    case .neutral: .secondary
    case .positive: .green
    case .attention: .orange
    case .critical: .red
    }
  }
}

/// Status as symbol + word. Never color alone.
struct HeliosStatusLabel: View {
  let status: HeliosStatus
  var prominent = false
  var compact = false
  /// Replaces the word for contexts where "Normal" reads wrong (e.g. "Available").
  var text: String? = nil

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: HeliosDesign.symbol(status))
        .font(.system(size: prominent ? 12 : 8, weight: .semibold))
        .foregroundStyle(HeliosDesign.color(status))
        .accessibilityHidden(true)
      Text(text ?? (compact ? status.shortLabel : status.label))
        .lineLimit(1)
        .foregroundStyle(status.isProblem ? HeliosDesign.color(status) : .secondary)
    }
    .font(prominent ? .title3.weight(.semibold) : .subheadline)
    .animation(HeliosDesign.statusChange, value: status)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(text ?? status.label)")
  }
}

/// The Helios sun is the overall status glyph: color and shape both change.
struct HeliosSunGlyph: View {
  let status: HeliosStatus
  var size: CGFloat = 34

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size, weight: .regular))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(color)
      .frame(width: size * 1.25, height: size * 1.25)
      .animation(HeliosDesign.statusChange, value: status)
      .accessibilityHidden(true)
  }

  private var symbol: String {
    switch status {
    case .good, .normal: "sun.max.fill"
    case .attention, .critical: "sun.max.trianglebadge.exclamationmark.fill"
    case .waiting: "sun.haze.fill"
    case .stale, .unavailable, .notPresent: "sun.min"
    }
  }

  private var color: Color {
    switch status {
    case .good, .normal: Color(red: 1.0, green: 0.57, blue: 0.08)
    case .attention: .orange
    case .critical: .red
    default: .secondary
    }
  }
}

/// Page section: a heading, an optional trailing accessory and content.
struct HeliosSection<Content: View, Accessory: View>: View {
  let title: String
  @ViewBuilder let accessory: Accessory
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 12)
        accessory
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension HeliosSection where Accessory == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    accessory = EmptyView()
    self.content = content()
  }
}

extension HeliosSection {
  init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
    self.title = title
    self.accessory = accessory()
    self.content = content()
  }
}

extension View {
  /// The rounded, hairline-bordered surface shared by grouped content.
  func heliosGroupSurface() -> some View {
    background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: HeliosDesign.groupCornerRadius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: HeliosDesign.groupCornerRadius)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
  }
}

/// System-Settings-style grouped surface. Rows are separated by inset dividers.
struct HeliosGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .heliosGroupSurface()
  }
}

/// One label/value row inside a group.
struct HeliosFactRow: View {
  let label: String
  let value: String
  var detail: String? = nil
  var showsDivider = true

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(label)
          if let detail {
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 12)
        Text(value)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
      .padding(.vertical, 7)
      if showsDivider { Divider() }
    }
    .accessibilityElement(children: .combine)
    .heliosMetricCopyActions(name: label, value: value)
  }
}

/// A list of facts with dividers only between rows.
struct HeliosFactList: View {
  let rows: [HeliosEvidence]

  var body: some View {
    HeliosGroup {
      // Static display rows: position is the identity (labels may repeat, e.g. app names).
      ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
        HeliosFactRow(
          label: row.label, value: row.value, detail: row.source,
          showsDivider: index < rows.count - 1)
      }
    }
  }
}

/// Inline "Why?" disclosure: meaning, why this state, and the evidence used.
struct HeliosWhyDisclosure: View {
  let assessment: HeliosAreaAssessment
  /// What this area measures, shown first.
  let meaning: String
  @State private var expanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 4) {
          Text(expanded ? "Hide explanation" : "Why?")
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .accessibilityHidden(true)
        }
        .font(.subheadline)
      }
      .buttonStyle(.link)
      .accessibilityLabel(expanded ? "Hide explanation" : "Why is \(assessment.area.title) \(assessment.status.label)?")

      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          Text(meaning)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(reason)
            .fixedSize(horizontal: false, vertical: true)
          if !assessment.evidence.isEmpty {
            HeliosFactList(rows: assessment.evidence)
          }
          if assessment.isPartial {
            Label("Some readings were missing. Helios judged only what it could read.",
              systemImage: "info.circle")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        .transition(.opacity)
      }
    }
  }

  private var reason: String {
    switch assessment.status {
    case .good, .normal:
      "Helios found nothing outside its limits. \(assessment.explanation)"
    case .attention, .critical:
      assessment.explanation
    case .waiting:
      "Helios has not completed its first reading yet."
    case .stale:
      "The latest reading is older than Helios accepts as current, so it is not judged."
    case .unavailable:
      "Helios could not read the values it needs for this area."
    case .notPresent:
      assessment.explanation
    }
  }
}

/// Quiet notice for data the user has chosen not to collect.
struct HeliosCollectionOffNotice: View {
  let title: String
  let module: HeliosTelemetryModule
  @ObservedObject var preferences: HeliosPreferences

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "pause.circle")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Button("Turn On") { preferences.setTelemetryModuleEnabled(module, enabled: true) }
        .controlSize(.small)
    }
    .font(.subheadline)
  }
}

/// Placeholder for absent content (macOS 13 has no ContentUnavailableView).
struct HeliosEmptyState: View {
  let symbol: String
  let title: String
  var message: String? = nil

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: symbol)
        .font(.system(size: 22))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(title).foregroundStyle(.secondary)
      if let message {
        Text(message).font(.subheadline).foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 18)
    .accessibilityElement(children: .combine)
  }
}

/// Large numeric value with a caption, used in page headers.
struct HeliosHeadlineValue: View {
  let value: String
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value)
        .font(.system(.title, design: .default).weight(.semibold))
        .monospacedDigit()
      Text(caption).font(.subheadline).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
