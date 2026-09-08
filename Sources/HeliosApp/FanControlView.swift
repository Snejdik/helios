import SwiftUI

struct FanControlView: View {
    @ObservedObject var model: FanControlModel
    @ObservedObject var client: DaemonClient
    let preflight: MetricResult<FanOwnershipPreflightSnapshot>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Fans", systemImage: "fan").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(controlLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            switch model.inventory.result {
            case .success(let inventory):
                if inventory.fans.isEmpty {
                    Text("Fanless Mac · Passive cooling").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(inventory.fans) { fan in
                        VStack(spacing: 3) {
                            HStack {
                                Text("Fan \(fan.id + 1)")
                                Spacer()
                                Text(rpm(fan.actualRPM)).monospacedDigit().fontWeight(.semibold)
                            }
                            HStack {
                                Text("Target \(rpm(fan.targetRPM))")
                                Spacer()
                                Text("\(number(fan.minimumRPM))–\(number(fan.maximumRPM)) RPM")
                            }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }.font(.system(size: 11))
                    }

                    FanModeControls(
                        selection: Binding(get: { model.selection }, set: { model.setMode($0) }),
                        targetRPM: $model.targetRPM,
                        bounds: model.sliderBounds,
                        boostEnabled: model.canSelectBoost,
                        overrideEnabled: model.canSelectOverride,
                        autoEnabled: model.canSelectAuto
                    )

                    if model.selection == .auto {
                        CoolingRulesEditor(model: model)
                    }

                    if case .success(let preflight) = preflight {
                        HStack(spacing: 6) {
                            Text("M4 ownership").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Text(heliosOwnsFans ? "Owned by Helios" : (isProductionProfileValidated(preflight) && preflight.isReadyForValidation ? "Clean" : preflight.summary))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(heliosOwnsFans ? Color.green : preflightColor(preflight.state))
                        }
                        .help(heliosOwnsFans ? "Helios currently owns the validated fan path. Safety releases still pre-empt Manual and Auto Rules immediately." : preflight.diagnosticText)
                        if isProductionProfileValidated(preflight) {
                            HStack(spacing: 6) {
                                Text("Safety profile").font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Text("Crash/restart ✓ · Sleep/wake ✓ · 95°C Max guard ✓")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.green)
                            }
                            .help("The pinned Mac16,1 / 25G83 profile passed graceful release, SIGKILL recovery, real sleep/wake restoration, Manual target changes, and a daemon-enforced 95°C factory-max floor.")
                            HStack(spacing: 6) {
                                Text("Production control").font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Text(client.fanControlAvailable ? "Boost + Manual + Auto Rules enabled" : "Unavailable")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(client.fanControlAvailable ? Color.green : Color.orange)
                            }
                        }
                        if !heliosOwnsFans, let reason = preflight.reasons.first {
                            Text(reason)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !model.canSelectControl {
                        Text(client.state == .connected ? (client.fanDetail.isEmpty ? "Waiting for fresh thermal and fan readings." : client.fanDetail) : "Fan control requires the signed, approved helper.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if model.selection == .auto, !model.autoDetail.isEmpty {
                        Text(model.autoDetail).font(.system(size: 10)).foregroundStyle(model.automaticEmergency ? .orange : .secondary)
                    } else if !client.fanDetail.isEmpty {
                        Text(client.fanDetail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            case .failure(let error):
                Text("Fan readings unavailable").font(.system(size: 11)).foregroundStyle(.secondary).help(error.localizedDescription)
            }
            if client.fanState == .recoveryRequired || client.fanState == .restoring || (!model.canSelectControl && client.fanState != .system) {
                Text("Automatic control is not yet confirmed.").font(.system(size: 11)).foregroundStyle(.orange)
                Button("Restore System") { model.setMode(.system) }.font(.system(size: 11))
            }
        }
    }

    private var heliosOwnsFans: Bool {
        client.fanState == .boost || client.fanState == .override
    }

    private var controlLabel: String {
        if model.selection == .auto {
            if model.automaticEmergency { return "Auto · Emergency Max" }
            if heliosOwnsFans { return "Auto Rules active" }
            if model.automaticDemandPercent != nil { return "Auto Rules waiting" }
            return "Auto Rules armed"
        }
        return switch client.fanState {
        case .system: "No Helios override"
        case .boost: "Boost active"
        case .override: "Manual active"
        case .restoring: "Restoring System"
        case .recoveryRequired: "Check fan control"
        }
    }

    private func number(_ value: MetricResult<Double>) -> String {
        guard let value = try? value.get(), value.isFinite else { return "—" }
        return String(format: "%.0f", value)
    }
    private func rpm(_ value: MetricResult<Double>) -> String { "\(number(value)) RPM" }

    private func isProductionProfileValidated(_ snapshot: FanOwnershipPreflightSnapshot) -> Bool {
        guard snapshot.evidence.modelIdentifier == FanOwnershipMachineProfile.primaryM4.modelIdentifier,
              snapshot.evidence.osBuild == FanOwnershipMachineProfile.primaryM4.osBuild,
              snapshot.evidence.fanCount == FanOwnershipMachineProfile.primaryM4.fanCount,
              snapshot.evidence.fans.count == 1,
              let fan = snapshot.evidence.fans.first else { return false }
        return fan.id == 0 && fan.modeKey == "F0Md" && fan.targetType == "flt " &&
               abs(fan.minimumRPM - 2317) <= 0.5 && abs(fan.maximumRPM - 6550) <= 0.5
    }

    private func preflightColor(_ state: FanOwnershipPreflightState) -> Color {
        switch state {
        case .readyForValidation: .green
        case .blocked: .orange
        case .unsupported: .gray
        }
    }
}

/// Value-only controls also used by deterministic presentation fixtures.
struct FanModeControls: View {
    @Binding var selection: FanControlSelection
    @Binding var targetRPM: Double
    let bounds: ClosedRange<Double>?
    let boostEnabled: Bool
    let overrideEnabled: Bool
    let autoEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Fan mode", selection: $selection) {
                ForEach(FanControlSelection.allCases, id: \.rawValue) { mode in
                    Text(mode.label).tag(mode).disabled(!modeEnabled(mode))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if selection == .boost {
                Text("Factory maximum cooling · daemon-locked to validated max RPM")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if selection == .override, let bounds = bounds {
                HStack {
                    Slider(value: $targetRPM, in: bounds, step: 50)
                        .accessibilityLabel("Manual target RPM")
                    Text(overrideValue(bounds))
                        .font(.system(size: 11)).monospacedDigit().frame(width: 112, alignment: .trailing)
                }
                Text("50 RPM steps · daemon-clamped to factory limits · explicit System release ramps down softly")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if selection == .auto {
                Text("Rules choose the highest active fan percentage. No matching rule returns control to macOS.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func overrideValue(_ bounds: ClosedRange<Double>) -> String {
        guard targetRPM.isFinite, bounds.upperBound > bounds.lowerBound else { return "— RPM" }
        let normalized = min(1, max(0, (targetRPM - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)))
        return String(format: "%.0f RPM · %.0f%%", targetRPM, normalized * 100)
    }

    private func modeEnabled(_ mode: FanControlSelection) -> Bool {
        switch mode {
        case .system: true
        case .boost: boostEnabled
        case .override: overrideEnabled
        case .auto: autoEnabled
        }
    }
}

private struct CoolingRulesEditor: View {
    @ObservedObject var model: FanControlModel
    @State private var editedProfile: CoolingPowerProfile = .powerAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().opacity(0.45)
            HStack {
                Text("Cooling Rules").font(.system(size: 11, weight: .semibold))
                Spacer()
                if let active = model.activePowerProfile {
                    Text("Using \(active.label)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(active == editedProfile ? .green : .secondary)
                } else {
                    Text("Power source unknown").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }

            Picker("Rule profile", selection: $editedProfile) {
                ForEach(CoolingPowerProfile.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            ForEach(Array(model.rules(for: editedProfile).enumerated()), id: \.element.id) { index, rule in
                CoolingRuleRow(model: model, profile: editedProfile, rule: rule,
                               canMoveUp: index > 0,
                               canMoveDown: index + 1 < model.rules(for: editedProfile).count)
                if index + 1 < model.rules(for: editedProfile).count { Divider().opacity(0.25) }
            }

            if model.rules(for: editedProfile).isEmpty {
                Text("No rules in this profile · macOS keeps System control until you add one.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Menu {
                    Button("Temperature Rule") { model.addRule(profile: editedProfile) }
                    Button("Always Rule") { model.addAlwaysRule(profile: editedProfile) }
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(model.rules(for: editedProfile).count >= CoolingRulesConfiguration.maximumRuleCount)
                .help("Add a threshold rule or an unconditional Always rule")

                Spacer()

                Menu("Copy") {
                    let other: CoolingPowerProfile = editedProfile == .powerAdapter ? .battery : .powerAdapter
                    Button("Copy all to \(other.label)") { model.copyRules(from: editedProfile, to: other) }
                }
                .controlSize(.small)

                Button("Safe Preset") { model.resetSafeRules() }
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("Downshift")
                Slider(value: Binding(get: { model.rulesConfiguration.transitionSeconds },
                                      set: { model.setTransitionSeconds($0) }),
                       in: 0...CoolingRulesConfiguration.maximumTransitionSeconds, step: 0.5)
                Text(String(format: "%.1f s", model.rulesConfiguration.transitionSeconds))
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            Text("0% = factory minimum · 100% = factory maximum · increases are immediate · 95°C trusted Max SoC always forces 100% in the daemon")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 1)
    }
}

private struct CoolingRuleRow: View {
    @ObservedObject var model: FanControlModel
    let profile: CoolingPowerProfile
    let rule: CoolingRule
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Toggle("", isOn: binding(\.enabled)).labelsHidden().controlSize(.mini)
                Picker("Fan", selection: binding(\.target)) {
                    ForEach(model.fanTargets, id: \.self) { target in
                        Text(model.targetLabel(target)).tag(target)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 96)

                Text("to").font(.system(size: 10)).foregroundStyle(.secondary)
                Stepper(value: binding(\.speedPercent), in: 0...100, step: 1) {
                    Text("\(rule.speedPercent)%").font(.system(size: 10)).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Text("when").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("Sensor", selection: binding(\.sensor)) {
                    ForEach(model.availableRuleSensors, id: \.source) { option in
                        Text(option.label).tag(option.source)
                    }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: .infinity)
                .help("Choose Always for an unconditional rule; sensor choices use the threshold shown to the right.")

                if rule.sensor.kind.usesThreshold {
                    Text(">").font(.system(size: 10)).foregroundStyle(.secondary)
                    Stepper(value: binding(\.thresholdCelsius), in: 20...120, step: 1) {
                        Text(String(format: "%.0f°C", rule.thresholdCelsius))
                            .font(.system(size: 10)).monospacedDigit().frame(width: 38, alignment: .trailing)
                    }
                    .controlSize(.small)
                }

                Button { model.moveRule(profile: profile, id: rule.id, offset: -1) } label: {
                    Image(systemName: "chevron.up")
                }.buttonStyle(.borderless).disabled(!canMoveUp).help("Move rule up")
                Button { model.moveRule(profile: profile, id: rule.id, offset: 1) } label: {
                    Image(systemName: "chevron.down")
                }.buttonStyle(.borderless).disabled(!canMoveDown).help("Move rule down")
                Button { model.removeRule(profile: profile, id: rule.id) } label: {
                    Image(systemName: "xmark.circle")
                }.buttonStyle(.borderless).help("Remove rule")
            }

            if model.activeRuleIDs.contains(rule.id), model.selection == .auto, model.activePowerProfile == profile {
                Text(model.automaticHardwareConfirmed
                     ? "Active · highest matching speed wins"
                     : "Matching · waiting for confirmed fan control")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(model.automaticHardwareConfirmed ? Color.green : Color.orange)
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CoolingRule, Value>) -> Binding<Value> {
        Binding(
            get: { model.rule(profile: profile, id: rule.id)?[keyPath: keyPath] ?? rule[keyPath: keyPath] },
            set: { value in model.updateRule(profile: profile, id: rule.id) { $0[keyPath: keyPath] = value } }
        )
    }
}
