import SuicaCore
import SwiftUI

/// The Lessons handed to Coding Agents in the last 30 days: a row per project on the left, and for
/// the chosen one the Lessons it got and its recent deliveries.
struct LessonsUsageView: View {
    let model: LessonsModel
    @State private var chosen: String?

    private var projects: [LessonUsageProject] { model.usage?.projects ?? [] }
    private var selected: LessonUsageProject? { projects.first { $0.id == chosen } ?? projects.first }

    var body: some View {
        VStack(spacing: 0) {
            if let text = model.usageError {
                NoticeBox(text: text, tint: .red).padding([.horizontal, .top], 12)
            }
            if model.usage == nil {
                if model.usageError == nil { ProgressView(Copy.loading) }
                Spacer()
            } else if projects.isEmpty {
                Text(Copy.lessonsUsageEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(get: { selected?.id }, set: { chosen = $0 })) {
                        ForEach(projects) { project in ProjectRow(project: project).tag(project.id) }
                    }
                    .frame(width: 340)
                    Divider()
                    if let selected {
                        ProjectDetail(project: selected, recent: model.recent(for: selected))
                    }
                }
            }
            Divider()
            Text(Copy.lessonsUsageEstimate)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }
}

private func name(_ project: LessonUsageProject) -> String {
    project.project ?? (project.scope as NSString).lastPathComponent
}

private struct ProjectRow: View {
    let project: LessonUsageProject

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(DisplayText.clean(name(project), max: 160)).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 6) {
                Text("\(project.deliveries)×")
                Text("\(Copy.tokens(project.tokens)) tok").accessibilityLabel(
                    "\(Copy.lessonsUsageTokens): \(Copy.tokens(project.tokens))")
                Spacer(minLength: 0)
                Text(project.lastDate.formatted(.relative(presentation: .named))).fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectDetail: View {
    let project: LessonUsageProject
    let recent: [LessonUsageEntry]

    var body: some View {
        List {
            Section {
                LabeledContent(Copy.lessonsUsageTokens, value: Copy.tokens(project.tokens))
                LabeledContent(Copy.lessonsUsageDeliveries, value: "\(project.deliveries)")
                LabeledContent(Copy.lessonsUsageSessions, value: "\(project.sessions)")
                LabeledContent(Copy.lessonsUsageLessons, value: "\(project.lessons)")
            } header: {
                Text(DisplayText.clean(project.project ?? project.scope, max: 200))
            }
            Section(Copy.lessonsUsageLessons) {
                ForEach(project.topLessons, id: \.id) { lesson in
                    HStack {
                        Text(lesson.title.map { DisplayText.clean($0, max: 160) } ?? "#\(lesson.id)").lineLimit(2)
                        Spacer(minLength: 0)
                        Text("\(lesson.times)×").foregroundStyle(.secondary)
                    }
                }
            }
            Section(Copy.lessonsUsageRecent) {
                ForEach(Array(recent.enumerated()), id: \.offset.description) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            Spacer(minLength: 0)
                            Text("\(Copy.tokens(entry.tokens)) tok").foregroundStyle(.secondary)
                        }
                        Text(([entry.tool ?? entry.source] + [entry.file].compactMap { $0 }).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.lessonIds.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
