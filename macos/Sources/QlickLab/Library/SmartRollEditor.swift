// Qlick Lab — GPL-3.0-only.
import SwiftUI

/// The rule editor of a Smart Roll: its name, then its rules, one row each (field, comparison, value), taken all
/// together, any of them or none of them; a group of rules nests with its own choice. The count of photographs that
/// meet them follows as they're written. Nothing on disk changes: a Smart Roll only lists.
struct SmartRollEditor: View {
    /// The sidebar's mark of a Smart Roll.
    static let symbol = "line.3.horizontal.decrease.circle"

    let lab: LabState
    @State var draft: SmartRollDraft
    @FocusState private var naming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol).font(.system(size: 15)).foregroundStyle(Theme.accent)
                Text(draft.editing == nil ? "New Smart Roll" : "Edit the Smart Roll").font(Theme.title(17)).foregroundStyle(Theme.paper)
            }
            Text("A Smart Roll holds every photograph of the catalog that meets its rules, found again as they change. The photographs stay where they are.")
                .font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Name").font(.system(size: 12)).foregroundStyle(Theme.dim).frame(width: 52, alignment: .leading)
                TextField("Smart Roll name", text: $draft.name).textFieldStyle(.roundedBorder).focused($naming)
            }
            if draft.editing == nil {
                HStack(spacing: 10) {
                    Text("In").font(.system(size: 12)).foregroundStyle(Theme.dim).frame(width: 52, alignment: .leading)
                    Picker("", selection: $draft.box) {
                        Text("“\(LabState.smartRollsBoxName)”" + (lab.projects.boxes.contains { $0.name == LabState.smartRollsBoxName } ? "" : " (new Box)")).tag(UUID?.none)
                        ForEach(lab.holderChoicesAll.filter { if case .box = $0.holder { return $0.name != LabState.smartRollsBoxName } else { return false } }, id: \.name) { choice in
                            if case .box(let id) = choice.holder { Text(choice.name).tag(Optional(id)) }
                        }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                }
            }
            Divider().overlay(Theme.line)
            ScrollView(.vertical) {
                RuleGroupEditor(group: $draft.rules, depth: 0, remove: nil)
                    .padding(.vertical, 2)
            }
            .frame(minHeight: 120, maxHeight: 360)
            .scrollIndicators(.automatic)
            Divider().overlay(Theme.line)
            HStack {
                let count = lab.countMatching(draft.rules)
                Text(lab.catalog.ready ? (count == 1 ? "1 photograph matches" : "\(count) photographs match") : "Reading the catalog's photographs…")
                    .font(Theme.value(12)).foregroundStyle(count > 0 ? Theme.paper : Theme.dim)
                Spacer()
                Button("Cancel") { lab.smartRollDraft = nil }.buttonStyle(QPillButtonStyle()).keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Create" : "Save") { finish() }
                    .buttonStyle(QPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .onAppear { naming = draft.editing == nil }
    }

    private func finish() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lab.finishSmartRoll(draft)
    }
}

/// One group of rules: whether all, any or none must be met, its rows, the groups inside it, and the + that adds.
struct RuleGroupEditor: View {
    @Binding var group: RuleGroup
    let depth: Int
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(depth == 0 ? "Photographs that meet" : "Meet").font(.system(size: 12.5)).foregroundStyle(Theme.label)
                Picker("", selection: $group.match) {
                    ForEach(RuleGroup.Match.allCases, id: \.self) { match in Text(match.title).tag(match) }
                }
                .labelsHidden().fixedSize()
                Text(depth == 0 ? "of these rules:" : "of:").font(.system(size: 12.5)).foregroundStyle(Theme.label)
                Spacer()
                if let remove {
                    Button(action: remove) { Image(systemName: "minus.circle").foregroundStyle(Theme.dim) }
                        .buttonStyle(.plain).help("Remove this group")
                }
            }
            ForEach($group.rules) { $rule in
                RuleRow(rule: $rule) { group.rules.removeAll { $0.id == rule.id } } add: {
                    let index = group.rules.firstIndex { $0.id == rule.id }.map { $0 + 1 } ?? group.rules.count
                    group.rules.insert(rule.field.startingRule, at: index)
                }
            }
            ForEach($group.groups) { $inner in
                let id = inner.id
                RuleGroupEditor(group: $inner, depth: depth + 1) { group.groups.removeAll { $0.id == id } }
                    .padding(.leading, 12).padding(.vertical, 6)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2) }
            }
            HStack(spacing: 14) {
                Button { group.rules.append(PhotoField.rating.startingRule) } label: {
                    Label("Add a Rule", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.label)
                if depth < 3 {
                    Button { group.groups.append(RuleGroup(match: .any, rules: [PhotoField.label.startingRule])) } label: {
                        Label("Add a Group", systemImage: "plus.square.on.square").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.label)
                    .help("Rules taken together, with their own all, any or none")
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One rule: the field, how it compares, the value; − takes it away, + adds one after it.
private struct RuleRow: View {
    @Binding var rule: SmartRule
    let remove: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { rule.field }, set: { field in
                guard field != rule.field else { return }
                let kind = rule.field.kind
                if field.kind == kind, field.kind != .choice { rule.field = field } else { rule = field.startingRule }
            })) {
                ForEach(PhotoField.editable) { field in Text(field.title).tag(field) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: Binding(get: { rule.op }, set: { op in
                if op == .inLast, rule.op != .inLast { rule.value = "30" }
                else if rule.op == .inLast, op != .inLast { rule.value = "" }
                rule.op = op
            })) {
                ForEach(rule.field.operators, id: \.self) { op in Text(op.title(for: rule.field.kind)).tag(op) }
            }
            .labelsHidden().frame(width: 140)
            value
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus.circle").font(.system(size: 13)).foregroundStyle(Theme.dim) }
                .buttonStyle(.plain).help("Remove this rule")
            Button(action: add) { Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(Theme.dim) }
                .buttonStyle(.plain).help("Add a rule after this one")
        }
    }

    @ViewBuilder private var value: some View {
        switch rule.field.kind {
        case .choice:
            Picker("", selection: $rule.value) {
                ForEach(rule.field.choices, id: \.value) { choice in Text(choice.title).tag(choice.value) }
            }
            .labelsHidden().frame(width: 160)
        case .date where rule.op == .inLast:
            HStack(spacing: 6) {
                TextField("30", text: $rule.value).textFieldStyle(.roundedBorder).frame(width: 60)
                Text("days").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        default:
            TextField(rule.field.placeholder, text: $rule.value).textFieldStyle(.roundedBorder).frame(minWidth: 120, maxWidth: 200)
                .overlay(alignment: .trailing) {
                    if !valid { Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn).padding(.trailing, 6).help(hint) }
                }
        }
    }

    /// A number or a date that can't be read is flagged where it's typed.
    private var valid: Bool {
        switch rule.field.kind {
        case .number: rule.value.isEmpty || SmartRule.number(rule.value) != nil
        case .date: rule.value.isEmpty || SmartRule.period(rule.value) != nil
        default: true
        }
    }

    private var hint: String {
        rule.field.kind == .date ? "A year, month or day: 2026, 2026-09 or 2026-09-19" : "A number, such as \(rule.field.placeholder)"
    }
}
