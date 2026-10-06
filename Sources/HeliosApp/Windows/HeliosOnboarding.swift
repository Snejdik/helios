import AppKit
import Combine
import SwiftUI

struct HeliosLaunchAtLoginView: View {
  let enabled: Bool
  let requiresApproval: Bool
  let busy: Bool
  let message: String?
  let setEnabled: (Bool) -> Void
  let openSettings: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Launch Helios at Login", isOn: Binding(get: { enabled }, set: { setEnabled($0) }))
        .disabled(busy || requiresApproval)
      Text(busy ? "Updating login setting…" : requiresApproval
        ? "Waiting for approval in System Settings."
        : "Separate from the fan helper.")
        .font(.subheadline).foregroundStyle(.tertiary)
      if requiresApproval {
        HStack {
          Button("Open Login Items Settings", action: openSettings)
          Button("Cancel") { setEnabled(false) }.disabled(busy)
          Spacer(minLength: 0)
        }
      }
      if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
    }
  }
}

/// Capture the route for this presentation: saving a choice must not change its Back path.
@MainActor
struct HeliosOnboardingFlow {
  /// `interface` is the goals page (the name is kept for existing callers).
  enum Page: String, CaseIterable { case interface, helper, diagnostics, support }
  private(set) var page: Page
  let asksForDiagnostics: Bool
  /// Whether the optional fan-helper step was part of this run (it follows the goals).
  private(set) var showsHelper = false

  init(consent: DiagnosticsConsentState, initialPage: Page = .interface) {
    asksForDiagnostics = consent == .notDecided
    page = initialPage
  }

  mutating func back() {
    switch page {
    case .support: page = asksForDiagnostics ? .diagnostics : (showsHelper ? .helper : .interface)
    case .diagnostics: page = showsHelper ? .helper : .interface
    case .helper, .interface: page = .interface
    }
  }

  mutating func advance(
    diagnostics: DiagnosticsController, shareDiagnostics: Bool, wantsFanHelper: Bool = false
  ) -> Bool {
    switch page {
    case .interface:
      showsHelper = wantsFanHelper
      page = wantsFanHelper ? .helper : (asksForDiagnostics ? .diagnostics : .support)
    case .helper:
      page = asksForDiagnostics ? .diagnostics : .support
    case .diagnostics:
      diagnostics.setAutomaticEnabled(shareDiagnostics)
      page = .support
    case .support:
      return true
    }
    return false
  }
}

extension HeliosMacTraits {
  /// What the first telemetry samples say about this Mac. Anything not yet
  /// sampled (or failed for another reason) stays unknown rather than guessed.
  init(snapshot: TelemetrySnapshot, now: Date = Date()) {
    var fans: Bool?
    if case .success(let inventory) = TelemetryFormatting.fresh(snapshot.fans, maxAge: 15, now: now) {
      fans = !inventory.fans.isEmpty
    }
    var battery: Bool?
    let observation = TelemetryFormatting.observation(snapshot.battery, maxAge: 30, now: now)
    switch observation.source {
    case .success: battery = true
    case .failure(let error): if error == HeliosMacAssessment.batteryAbsentError { battery = false }
    }
    self.init(hasFans: fans, hasBattery: battery)
  }
}

/// Publishes this Mac's traits to the welcome page, only when they change.
@MainActor
final class HeliosMacTraitsObserver: ObservableObject {
  @Published private(set) var traits: HeliosMacTraits
  private var subscription: AnyCancellable?

  init(model: OverviewViewModel?, initial: HeliosMacTraits = .unknown) {
    traits = model.map { HeliosMacTraits(snapshot: $0.snapshot) } ?? initial
    subscription = model?.$snapshot
      .map { HeliosMacTraits(snapshot: $0) }
      .removeDuplicates()
      .sink { [weak self] in self?.traits = $0 }
  }
}

struct HeliosOnboardingView: View {
  typealias Page = HeliosOnboardingFlow.Page

  @ObservedObject var preferences: HeliosPreferences
  @ObservedObject var diagnostics: DiagnosticsController
  /// Used only by the optional fan-helper step; nil in offline renders and tests.
  let service: DaemonService?
  let onFinish: () -> Void
  @StateObject private var traitsObserver: HeliosMacTraitsObserver
  @State private var goals: Set<HeliosGoal> = []
  /// Once the person edits the goals, new detection no longer replaces them.
  @State private var customized = false
  @State private var showsCustomize = false
  @State private var flow: HeliosOnboardingFlow
  @State private var shareDiagnostics = false
  @State private var previewPayload: FrozenDiagnosticsPayload?
  @State private var showingPreview = false
  @State private var previewError: String?

  init(
    preferences: HeliosPreferences, diagnostics: DiagnosticsController,
    service: DaemonService? = nil, model: OverviewViewModel? = nil,
    traits: HeliosMacTraits = .unknown, initialGoals: Set<HeliosGoal>? = nil,
    initialPage: Page = .interface, onFinish: @escaping () -> Void
  ) {
    let observer = HeliosMacTraitsObserver(model: model, initial: traits)
    _traitsObserver = StateObject(wrappedValue: observer)
    _goals = State(initialValue: initialGoals ?? HeliosGoalPlan.recommendedGoals(for: observer.traits))
    _customized = State(initialValue: initialGoals != nil)
    self.preferences = preferences
    self.diagnostics = diagnostics
    self.service = service
    self.onFinish = onFinish
    _flow = State(initialValue: HeliosOnboardingFlow(
      consent: diagnostics.preferences.consent, initialPage: initialPage))
  }

  private var traits: HeliosMacTraits { traitsObserver.traits }
  private var plan: HeliosGoalPlan { HeliosGoalPlan.make(for: goals, traits: traits) }
  private var wantsFanHelper: Bool { plan.wantsFanHelper }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        Group {
          switch flow.page {
          case .interface: goalsPage
          case .helper: helperPage
          case .diagnostics: diagnosticsPage
          case .support: supportPage
          }
        }
        .frame(maxWidth: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      HStack {
        if flow.page == .interface {
          Text("You can change this any time in Settings → General.")
            .font(.subheadline).foregroundStyle(.secondary)
        } else {
          Button("Back") { flow.back() }
          Text(footerNote).font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        Button(flow.page == .support ? "Finish Setup" : "Continue", action: continueAction)
          .keyboardShortcut(.defaultAction)
      }
      .padding(18)
    }
    .frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 560)
    .background(.regularMaterial)
    .onAppear { shareDiagnostics = diagnostics.preferences.automaticEnabled }
    .sheet(isPresented: $showingPreview) {
      if let previewPayload {
        DiagnosticsPayloadView(
          title: "Beta diagnostics preview",
          explanation: "This local preview shows the exact automatic diagnostics body. It is not sent from this screen.",
          payload: previewPayload)
      }
    }
  }

  private var footerNote: String {
    switch flow.page {
    case .helper: "You can set up fan control later in Settings → Cooling."
    case .diagnostics: "You can change this later in Settings → Privacy & Diagnostics."
    default: "That's everything. Thanks for trying Helios."
    }
  }

  private var goalsPage: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        HeliosApplicationIcon(size: 54)
        Text("Welcome to Helios").font(.system(size: 26, weight: .semibold))
        Text("Helios sets itself up for this Mac. You can change anything later.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 520)
      }
      .padding(.top, 28)
      .padding(.bottom, 20)

      VStack(alignment: .leading, spacing: 10) {
        Text("Recommended for this Mac").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 0) {
          recommendationRow(
            "Menu bar", plan.menuBarMetrics.isEmpty
              ? "Just the Helios icon" : plan.menuBarMetrics.map(\.shortLabel).joined(separator: " · "))
          Divider()
          recommendationRow(
            "Fan control", wantsFanHelper
              ? "Optional setup comes next" : (traits.hasFans == false ? "This Mac has no fan" : "Off"))
        }
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        DisclosureGroup("Customize…", isExpanded: $showsCustomize) {
          HeliosGoalPicker(
            selection: Binding(get: { goals }, set: { goals = $0; customized = true }),
            available: HeliosGoal.available(on: traits))
            .padding(.top, 10)
        }
        .font(.system(size: 13))
      }
      .frame(maxWidth: 520)
      .padding(.horizontal, 24)
      .padding(.bottom, 20)
    }
    .onChange(of: traitsObserver.traits) { updated in
      guard !customized else { return }
      goals = HeliosGoalPlan.recommendedGoals(for: updated)
    }
  }

  private func recommendationRow(_ title: String, _ value: String) -> some View {
    HStack {
      Text(title)
      Spacer(minLength: 12)
      Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
    .font(.system(size: 13))
    .padding(.vertical, 10)
    .accessibilityElement(children: .combine)
  }

  private var helperPage: some View {
    VStack(spacing: 18) {
      Image(systemName: "fan").font(.system(size: 40)).foregroundStyle(.secondary)
      Text("Set up fan control").font(.system(size: 26, weight: .semibold))
      Text("Reading temperatures and fan speed works right away. Controlling the fans needs a small signed helper, and macOS will ask you to approve it.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
      if let service {
        HeliosHelperSetupRow(service: service)
      } else {
        Button("Install Helper") {}.disabled(true)
      }
      Text("Skip it and nothing is installed. macOS manages the fans by default, which is the safest choice.")
        .font(.subheadline).foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
    }
    .padding(28)
  }

  private var diagnosticsPage: some View {
    VStack(spacing: 20) {
      HeliosApplicationIcon(size: 54)
      Text("Help Helios work on more Macs").font(.system(size: 26, weight: .semibold))
      Text("Helios is new, and every Mac model behaves a little differently. If you share anonymous technical diagnostics, I can fix problems on Macs I do not own. Nothing is sent unless you turn this on, and you can see exactly what would be sent first.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)

      VStack(alignment: .leading, spacing: 12) {
        Toggle("Share anonymous diagnostics", isOn: $shareDiagnostics)
          .toggleStyle(.checkbox)
          .font(.system(size: 13, weight: .medium))
        Button("See exactly what is shared", action: showAutomaticPreview)
          .buttonStyle(.link)
        if let previewError {
          Text(previewError).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .padding(18)
      .frame(width: 440, alignment: .leading)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))

      Text("Off by default. It does not change any Helios feature.")
        .font(.subheadline).foregroundStyle(.tertiary)
    }
    .padding(24)
  }

  private var supportPage: some View {
    VStack(spacing: 20) {
      HeliosApplicationIcon(size: 54)
      Text("Support Helios").font(.system(size: 26, weight: .semibold))
      Text("Helios is free and built by one person alongside university studies. If it is useful to you, a coffee helps pay for test hardware and keeps development going.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
      Button {
        guard let url = URL(string: "https://buymeacoffee.com/snejda") else { return }
        NSWorkspace.shared.open(url)
      } label: {
        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
          .padding(.horizontal, 10).padding(.vertical, 3)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      Text("Optional. Helios stays fully usable without it.")
        .font(.subheadline).foregroundStyle(.tertiary)
    }
    .padding(28)
  }

  private func continueAction() {
    guard flow.advance(
      diagnostics: diagnostics, shareDiagnostics: shareDiagnostics, wantsFanHelper: wantsFanHelper)
    else { return }
    preferences.completeOnboarding(goals: goals, traits: traits)
    onFinish()
  }

  private func showAutomaticPreview() {
    do {
      previewPayload = try diagnostics.makeHealthPayload(
        type: .automaticHealth, reason: .initialOptIn)
      previewError = nil
      showingPreview = true
    } catch {
      previewError = "A safe diagnostics preview is not available yet. Nothing was sent."
    }
  }
}
