import SwiftUI

/// The ordered fallback rules, edited in place. Rules aren't Identifiable, so rows go by index.
struct FallbackRulesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rules = model.alarmSettings.fallbackRules
        Section {
            ForEach(rules.indices, id: \.self) { index in
                FallbackRuleRow(position: index + 1, rule: rules[index], channels: model.channels) { change in
                    update { change(&$0[index]) }
                } remove: {
                    update { $0.remove(at: index) }
                }
                .contextMenu {
                    Button("Move Up") { update { $0.swapAt(index, index - 1) } }
                        .disabled(index == 0)
                    Button("Move Down") { update { $0.swapAt(index, index + 1) } }
                        .disabled(index == rules.count - 1)
                    Divider()
                    Button("Remove", role: .destructive) { update { $0.remove(at: index) } }
                }
            }
            .onMove { from, to in update { $0.move(fromOffsets: from, toOffset: to) } }
            HStack {
                if rules.isEmpty {
                    Text("No rules: when nothing is new, the alarm sound rings.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Add Rule", systemImage: "plus") {
                    ForEach(FallbackRuleKind.allCases, id: \.self) { kind in
                        Button(AlarmText.kindTitle(kind)) { update { $0.append(FallbackRule(kind: kind)) } }
                    }
                }
                .fixedSize()
            }
        } header: {
            Text("When There's Nothing New")
        } footer: {
            Text("Rules are tried from the top; the first one that finds a video wins. Drag to reorder.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func update(_ change: (inout [FallbackRule]) -> Void) {
        model.updateAlarmSettings { change(&$0.fallbackRules) }
    }
}

/// "1.  [Newest unplayed]  from  [Any channel]  in the last  7 days [±]   (−)"
private struct FallbackRuleRow: View {
    let position: Int
    let rule: FallbackRule
    let channels: [Channel]
    let change: ((inout FallbackRule) -> Void) -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(position).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            Picker("Rule", selection: Binding(get: { rule.kind }, set: { kind in change { $0.kind = kind } })) {
                ForEach(FallbackRuleKind.allCases, id: \.self) { kind in
                    Text(AlarmText.kindTitle(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 160, alignment: .leading)
            Text("from").foregroundStyle(.secondary)
            Picker("Channel", selection: Binding(get: { rule.channelId }, set: { id in change { $0.channelId = id } })) {
                Text("Any channel").tag(String?.none)
                Divider()
                ForEach(channels) { channel in
                    Text(channel.title).tag(Optional(channel.id))
                }
                if let id = rule.channelId, !channels.contains(where: { $0.id == id }) {
                    Text("Unfollowed channel").tag(Optional(id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 200, alignment: .leading)
            if rule.kind.usesDays {
                Text("in the last").foregroundStyle(.secondary)
                Committed(rule.withinDays, commit: { days in change { $0.withinDays = days } }) { days, editing in
                    StepperValue(text: days.wrappedValue == 1 ? "1 day" : "\(days.wrappedValue) days") {
                        Stepper("Days", value: days, in: FallbackRule.daysRange, onEditingChanged: editing)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove this rule")
        }
        .padding(.vertical, 2)
        .help(AlarmText.describe(rule, channelTitle: channels.first { $0.id == rule.channelId }?.title))
    }
}
