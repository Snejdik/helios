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

  /// The diagnostics page is always part of the welcome: it is the one place most people
  /// see the choice. `consent` only decides the starting state of its checkbox.
  init(consent: DiagnosticsConsentState, initialPage: Page = .interface) {
    asksForDiagnostics = true
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
    diagnostics: DiagnosticsController, shareDiagnostics: Bool, wantsFanHelper: Bool = false,
    weeklyCompatibility: Bool? = nil
  ) -> Bool {
    switch page {
    case .interface:
      showsHelper = wantsFanHelper
      page = wantsFanHelper ? .helper : (asksForDiagnostics ? .diagnostics : .support)
    case .helper:
      page = asksForDiagnostics ? .diagnostics : .support
    case .diagnostics:
      diagnostics.setAutomaticEnabled(shareDiagnostics)
      if let weeklyCompatibility { diagnostics.setWeeklyCompatibilityEnabled(weeklyCompatibility) }
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
  @State private var flow: HeliosOnboardingFlow
  @State private var shareDiagnostics = false
  @State private var weeklyCompatibility = false
  @State private var preparingCompatibilityPreview = false
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
  /// Only when the person chose cooling, and not again once the helper is installed.
  private var wantsFanHelper: Bool { plan.wantsFanHelper && service?.state != .installed }

  var body: some View {
    VStack(spacing: 0) {
      GeometryReader { proxy in
        ScrollView {
          Group {
            switch flow.page {
            case .interface: goalsPage
            case .helper: helperPage
            case .diagnostics: diagnosticsPage
            case .support: supportPage
            }
          }
          // Short pages sit in the middle of the window instead of at the top.
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()
      HStack {
        if flow.page != .interface { Button("Back") { flow.back() } }
        Spacer()
        Button(flow.page == .support ? "Finish Setup" : "Continue", action: continueAction)
          .keyboardShortcut(.defaultAction)
      }
      .padding(18)
    }
    .frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 560)
    .background(.regularMaterial)
    .onAppear {
      shareDiagnostics = diagnostics.preferences.automaticEnabled
      weeklyCompatibility = diagnostics.preferences.weeklyCompatibilityEnabled
    }
    .sheet(isPresented: $showingPreview) {
      if let previewPayload {
        DiagnosticsPayloadView(
          title: previewPayload.reportType.isCompatibility
            ? "Weekly compatibility report preview" : "Beta diagnostics preview",
          explanation: previewPayload.reportType.isCompatibility
            ? "This local preview shows exactly what a weekly compatibility report from this Mac contains. It is not sent from this screen."
            : "This local preview shows the exact automatic diagnostics body. It is not sent from this screen.",
          payload: previewPayload)
      }
    }
  }

  private var goalsPage: some View {
    VStack(spacing: 18) {
      HStack(spacing: 14) {
        HeliosApplicationIcon(size: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text("Welcome to Helios").font(.system(size: 24, weight: .semibold))
          Text("What should it do for you?").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      HeliosGoalPicker(
        selection: Binding(get: { goals }, set: { goals = $0; customized = true }),
        available: HeliosGoal.available(on: traits), compact: true)
    }
    .frame(maxWidth: 640)
    .padding(24)
    .onChange(of: traitsObserver.traits) { updated in
      guard !customized else { return }
      goals = HeliosGoalPlan.recommendedGoals(for: updated)
    }
  }

  private func pageHeader(_ title: String, _ text: String, symbol: String? = nil) -> some View {
    VStack(spacing: 12) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.secondary)
      } else {
        HeliosApplicationIcon(size: 48)
      }
      Text(title).font(.system(size: 24, weight: .semibold))
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 470)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var helperPage: some View {
    VStack(spacing: 18) {
      pageHeader(
        "Fan control",
        "Helios needs a small helper to control the fans. macOS asks you to allow it once.",
        symbol: "fan")
      if let service {
        HeliosHelperSetupRow(service: service)
      } else {
        Button("Install Helper") {}.disabled(true)
      }
      Text("Optional. Skip it and macOS keeps managing the fans.")
        .font(.subheadline).foregroundStyle(.tertiary)
    }
    .padding(28)
  }

  private var diagnosticsPage: some View {
    VStack(spacing: 18) {
      pageHeader(
        "Help me test Helios",
        "I am a student building Helios on my own, with just one Mac to test on. Anonymous reports from your Mac show me what to fix on the Macs I do not have.")
      VStack(alignment: .leading, spacing: 14) {
        diagnosticsChoice(
          isOn: $shareDiagnostics, title: "Daily health report",
          detail: "Which parts of Helios work on this Mac.",
          previewTitle: "Preview", preview: showAutomaticPreview)
        diagnosticsChoice(
          isOn: $weeklyCompatibility, title: "Weekly compatibility report",
          detail: "Which sensors and fans this Mac has.",
          previewTitle: preparingCompatibilityPreview ? "Reading…" : "Preview",
          preview: showCompatibilityPreview)
        if let previewError {
          Text(previewError).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .padding(18)
      .frame(width: 440, alignment: .leading)
      .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
      Text("Anonymous: no names, files or apps. Change it any time in Settings.")
        .font(.subheadline).foregroundStyle(.tertiary)
    }
    .padding(24)
  }

  private func diagnosticsChoice(
    isOn: Binding<Bool>, title: String, detail: String, previewTitle: String,
    preview: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Toggle(title, isOn: isOn)
          .toggleStyle(.checkbox)
          .font(.system(size: 13, weight: .medium))
        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 20)
      }
      Spacer(minLength: 8)
      Button(previewTitle, action: preview).buttonStyle(.link).font(.system(size: 12))
    }
  }

  private var supportPage: some View {
    VStack(spacing: 18) {
      pageHeader(
        "Thank you for trying Helios",
        "Helios is free, and I make it in my spare time next to university. If it makes your Mac a little better, a coffee would honestly make my day, and it helps pay for the Macs I cannot test on yet.")
      Button {
        guard let url = URL(string: "https://buymeacoffee.com/snejda") else { return }
        NSWorkspace.shared.open(url)
      } label: {
        Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
          .padding(.horizontal, 10).padding(.vertical, 3)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      Text("Completely optional. Helios stays free either way.")
        .font(.subheadline).foregroundStyle(.tertiary)
    }
    .padding(28)
  }

  private func continueAction() {
    guard flow.advance(
      diagnostics: diagnostics, shareDiagnostics: shareDiagnostics, wantsFanHelper: wantsFanHelper,
      weeklyCompatibility: weeklyCompatibility)
    else { return }
    preferences.completeOnboarding(goals: goals, traits: traits)
    onFinish()
  }

  private func showCompatibilityPreview() {
    guard !preparingCompatibilityPreview else { return }
    preparingCompatibilityPreview = true
    Task {
      defer { preparingCompatibilityPreview = false }
      do {
        previewPayload = try await diagnostics.makeCompatibilityPayload(
          type: .automaticCompatibility, reason: .initialOptIn)
        previewError = nil
        showingPreview = true
      } catch {
        previewError = "A compatibility preview is not available right now. Nothing was sent."
      }
    }
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
