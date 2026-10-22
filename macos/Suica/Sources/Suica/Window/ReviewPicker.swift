import SuicaCore
import SwiftUI

/// The sections of the skill and model drawer.
enum ReviewPickerPart: Hashable { case skill, model }

/// The skills and models an Agent Review can use, picked by clicking, in a drawer beside
/// Configuration or an MR. The drawer only sets the bindings; the page decides what a pick does.
struct ReviewPicker<Footer: View>: View {
    typealias Part = ReviewPickerPart

    let loader: ReviewOptionsLoader
    let parts: [Part]
    /// The selected skill's name.
    @Binding var skill: String
    /// Nil for the CLI's own default.
    @Binding var model: String?
    /// Offer "CLI default": always in Configuration; for one review only when it is the config's default.
    var offersCliDefault = true
    /// The CLI to list models for, such as an unsaved Model CLI; nil for the saved one.
    var cli: String?
    @ViewBuilder var footer: () -> Footer

    @State private var query = ""
    /// With both parts, the one on screen: the skill list is long enough to hide the models.
    @State private var shown: Part?
    @State private var otherModel = ""
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if parts.count > 1 {
                Picker(Copy.pickerTitle, selection: Binding(get: { shown ?? parts[0] }, set: { shown = $0 })) {
                    Text(Copy.pickerSkill).tag(Part.skill)
                    Text(Copy.pickerModel).tag(Part.model)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            if let options = loader.options {
                list(options)
            } else if let error = loader.errorText {
                failure(error)
            } else {
                ProgressView(Copy.loading).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            footer()
        }
        .navigationTitle(Copy.pickerTitle)
        .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        .task(id: cli) { await loader.load(cli: cli) }
    }

    private func failure(_ text: String) -> some View {
        VStack(spacing: 10) {
            Text(DisplayText.clean(text, max: 400)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(Copy.tryAgain) { Task { await loader.load(cli: cli) } }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ options: ReviewOptions) -> some View {
        List {
            switch shown ?? parts.first {
            case .skill: skillSection(options)
            case .model: modelSection(options)
            case nil: EmptyView()
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .top) {
            if loader.loading { ProgressView().controlSize(.small).padding(6) }
        }
    }

    // MARK: Skills

    private func skillSection(_ options: ReviewOptions) -> some View {
        let matches = options.skills(matching: query)
        return Section(Copy.pickerSkill) {
            TextField(Copy.searchSkills, text: $query, prompt: Text(Copy.searchSkills))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Copy.searchSkills)
            if matches.isEmpty {
                Text(Copy.noSkillsMatch(query)).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(matches) { item in
                PickerRow(selected: item.name == skill) {
                    skill = item.name
                } label: {
                    HStack(spacing: 6) {
                        Text(DisplayText.clean(item.shortName, max: 80)).fontWeight(.medium).foregroundStyle(.primary)
                        if item.name == options.defaults.skill { DefaultTag() }
                    }
                    if let plugin = item.plugin {
                        Text(DisplayText.clean(plugin, max: 60)).font(.caption).foregroundStyle(.secondary)
                    }
                    if item.missing {
                        Text(Copy.skillNotInstalled).font(.caption).foregroundStyle(.orange)
                    } else if !item.description.isEmpty {
                        Text(DisplayText.clean(item.description, max: 300))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .disabled(item.missing)
                .accessibilityLabel(item.name)
            }
        }
    }

    // MARK: Models

    @ViewBuilder private func modelSection(_ options: ReviewOptions) -> some View {
        let listed = options.models.contains { $0.name == model }
        Section(options.cli == nil ? Copy.pickerModel : Copy.pickerModels(for: options.cli)) {
            if options.cli == nil {
                Text(Copy.noCli).font(.callout).foregroundStyle(.secondary)
            } else if options.models.isEmpty {
                Text(Copy.noModelsListed).font(.callout).foregroundStyle(.secondary)
            }
            if offersCliDefault || options.defaults.model == nil {
                PickerRow(selected: model == nil) {
                    model = nil
                } label: {
                    HStack(spacing: 6) {
                        Text(Copy.cliDefaultModel).fontWeight(.medium).foregroundStyle(.primary)
                        if options.defaults.model == nil { DefaultTag() }
                    }
                }
            }
            ForEach(options.models) { item in
                PickerRow(selected: item.name == model) {
                    model = item.name
                } label: {
                    HStack(spacing: 6) {
                        Text(DisplayText.clean(item.label, max: 60)).fontWeight(.medium).foregroundStyle(.primary)
                        if item.label.lowercased() != item.name.lowercased() {
                            Text(DisplayText.clean(item.name, max: 80)).foregroundStyle(.secondary)
                        }
                        if item.name == options.defaults.model { DefaultTag() }
                    }
                    if !item.description.isEmpty {
                        Text(DisplayText.clean(item.description, max: 300))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            otherModelRow(selected: model != nil && !listed)
        }
        .onAppear { if let model, !listed { otherModel = model } }
    }

    /// Any name the CLI takes, for a model the list lacks.
    private func otherModelRow(selected: Bool) -> some View {
        let valid = ReviewChoice.isValidModel(otherModel)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Copy.otherModel).fontWeight(.medium).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
            }
            TextField(Copy.otherModelPrompt, text: $otherModel, prompt: Text(Copy.otherModelPrompt))
                .textFieldStyle(.roundedBorder)
                .focused($otherFocused)
                .onSubmit { if valid { model = otherModel } }
                .onChange(of: otherModel) { _, name in
                    if otherFocused && ReviewChoice.isValidModel(name) { model = name }
                }
            if !otherModel.isEmpty && !valid {
                Text(Copy.otherModelInvalid).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One choice in the drawer: the whole row clicks, a checkmark marks the selected one.
private struct PickerRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2, content: label)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct DefaultTag: View {
    var body: some View {
        Text(Copy.defaultTag)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}

extension ReviewPicker where Footer == EmptyView {
    init(
        loader: ReviewOptionsLoader, parts: [Part], skill: Binding<String>, model: Binding<String?>,
        cli: String? = nil
    ) {
        self.init(loader: loader, parts: parts, skill: skill, model: model, cli: cli, footer: { EmptyView() })
    }
}
