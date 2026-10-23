import SuicaCore
import SwiftUI

/// Over My MRs: the Filter button with how many choices are on and, while some are, how many MRs
/// pass and a way to clear them.
struct MyMRFilterBar: View {
    @Binding var filter: MyMRFilter
    let list: ReviewListDocument
    let query: String
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showing.toggle() } label: {
                Label(
                    Copy.filterLabel(filter.count),
                    systemImage: filter.isEmpty
                        ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(Copy.filterHelp)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                MyMRFilterPanel(filter: $filter, list: list)
            }
            Spacer(minLength: 0)
            if !filter.isEmpty {
                Text(
                    Copy.shownOf(
                        list.yourMergeRequests(matching: query, filter: filter).count,
                        list.yourMergeRequests(matching: query).count)
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Button(Copy.clearFilters) { filter = MyMRFilter() }
                    .buttonStyle(.borderless)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The filter choices: approval and pipeline as checkboxes, and the repositories with a search.
private struct MyMRFilterPanel: View {
    @Binding var filter: MyMRFilter
    let list: ReviewListDocument
    @State private var repositoryQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            group(Copy.filterApproval) {
                ForEach(MyMRFilter.Status.approval, id: \.self) { statusToggle($0) }
            }
            group(Copy.filterPipeline) {
                ForEach(MyMRFilter.Status.pipeline, id: \.self) { statusToggle($0) }
            }
            group(Copy.filterRepository) {
                TextField(Copy.searchRepositories, text: $repositoryQuery)
                    .textFieldStyle(.roundedBorder)
                let paths = MyMRFilter.repositories(list.yourRepositories, matching: repositoryQuery)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if paths.isEmpty {
                            Text(Copy.noRepositoriesMatch).foregroundStyle(.secondary)
                        }
                        ForEach(paths, id: \.self) { repositoryToggle($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button(Copy.clearFilters) { filter = MyMRFilter() }
                .disabled(filter.isEmpty)
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 300)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Each choice with how many of your MRs it would show on its own.
    private func statusToggle(_ status: MyMRFilter.Status) -> some View {
        let count = list.yourMergeRequests.filter(MyMRFilter(statuses: [status]).admits).count
        return Toggle(isOn: binding(status, in: \.statuses)) {
            Text("\(Copy.filterStatus(status)) ").foregroundStyle(.primary)
                + Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func repositoryToggle(_ path: String) -> some View {
        let count = list.yourMergeRequests.filter { $0.repository == path }.count
        return Toggle(isOn: binding(path, in: \.repositories)) {
            HStack(spacing: 4) {
                Text(DisplayText.clean(path, max: 120)).lineLimit(1).truncationMode(.head).help(path)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func binding<Element: Hashable>(
        _ element: Element, in set: WritableKeyPath<MyMRFilter, Set<Element>>
    ) -> Binding<Bool> {
        Binding(
            get: { filter[keyPath: set].contains(element) },
            set: { on in
                if on { filter[keyPath: set].insert(element) } else { filter[keyPath: set].remove(element) }
            })
    }
}
