import SuicaCore
import SwiftUI

/// The MR's head pipeline under its header: one line with how many jobs are done, the stage it is
/// in and how long it has run, a bar with a segment per stage filled as its jobs finish, and the
/// jobs themselves behind Show jobs.
struct PipelineProgressView: View {
    let pipeline: PipelineDetail
    @State private var showsJobs = false
    @Environment(\.openURL) private var openURL
    @Environment(\.motionLevel) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            StageBar(stages: pipeline.stages)
            if showsJobs { jobs }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.5)))
    }

    private var summary: some View {
        let progress = pipeline.progress
        return HStack(spacing: 6) {
            Image(systemName: PipelineLook.symbol(pipeline.status))
                .foregroundStyle(PipelineLook.tint(pipeline.status))
                .symbolEffect(.pulse, isActive: pipeline.isActive && motion != .off)
            Text(Copy.pipelineNumber(pipeline.iid)).fontWeight(.semibold)
            Text(Copy.jobStatus(pipeline.status)).foregroundStyle(PipelineLook.tint(pipeline.status))
            Text("·").foregroundStyle(.tertiary)
            Text(Copy.pipelineJobsDone(progress.done, of: progress.total)).monospacedDigit()
            if let stage = pipeline.currentStage {
                Text("·").foregroundStyle(.tertiary)
                Text(Copy.pipelineStageNow(DisplayText.clean(stage.name, max: 40)))
            }
            elapsed
            Spacer(minLength: 8)
            Button(showsJobs ? Copy.pipelineHideJobs : Copy.pipelineShowJobs) {
                withMotion(Motion.content, motion) { showsJobs.toggle() }
            }
            .buttonStyle(.link)
            if let url = DisplayText.safeURL(pipeline.url) {
                Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help(Copy.openPipeline)
                    .accessibilityLabel(Copy.openPipeline)
            }
        }
        .font(.callout)
        .lineLimit(1)
    }

    /// A running pipeline's time ticks on its own; a finished one says how long it took.
    @ViewBuilder private var elapsed: some View {
        if let start = pipeline.startedDate {
            Text("·").foregroundStyle(.tertiary)
            if let end = pipeline.finishedDate {
                Text(Copy.pipelineTook(PipelineLook.duration(from: start, to: end)))
                    .foregroundStyle(.secondary)
            } else if pipeline.isActive {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Each stage with its jobs, side by side while they fit and stacked otherwise.
    private var jobs: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(pipeline.stages.enumerated()), id: \.offset) { _, stage in
                VStack(alignment: .leading, spacing: 4) {
                    Text(DisplayText.clean(stage.name, max: 60))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(Array(stage.jobs.enumerated()), id: \.offset) { _, job in jobRow(job) }
                }
            }
        }
        .padding(.top, 2)
    }

    private func jobRow(_ job: PipelineJob) -> some View {
        HStack(spacing: 6) {
            Image(systemName: PipelineLook.symbol(job.status))
                .foregroundStyle(PipelineLook.tint(job.status, allowFailure: job.allowFailure))
                .frame(width: 16)
            Text(DisplayText.clean(job.name, max: 80)).lineLimit(1)
            Text(Copy.jobStatus(job.status)).foregroundStyle(.secondary)
            if job.allowFailure && job.status == "FAILED" {
                Badge(text: Copy.allowedToFail, tint: .orange)
            }
            Spacer(minLength: 8)
            if let start = job.startedDate {
                if let end = job.finishedDate {
                    Text(PipelineLook.duration(from: start, to: end)).foregroundStyle(.tertiary).monospacedDigit()
                } else if job.isActive {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            if let url = job.url.flatMap(DisplayText.safeURL) {
                Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help(Copy.openJob)
                    .accessibilityLabel(Copy.openJob)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// A segment per stage, as wide as its share of the jobs, filled as far as its jobs are done.
private struct StageBar: View {
    let stages: [PipelineStage]

    var body: some View {
        GeometryReader { geometry in
            let weights = stages.map { CGFloat(max($0.jobs.count, 1)) }
            let gap: CGFloat = 3
            let usable = max(geometry.size.width - gap * CGFloat(max(stages.count - 1, 0)), 0)
            let total = max(weights.reduce(0, +), 1)
            HStack(spacing: gap) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    let look = PipelineLook.stage(stage)
                    Capsule()
                        .fill(look.tint.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(look.tint).frame(width: usable * weights[index] / total * look.filled)
                        }
                        .frame(width: usable * weights[index] / total)
                        .help("\(stage.name): \(Copy.jobStatus(stage.status))")
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Symbols, colours and durations shared by the pipeline line, the bar and the jobs.
enum PipelineLook {
    static func symbol(_ status: String) -> String {
        switch status {
        case "SUCCESS": "checkmark.circle.fill"
        case "FAILED": "xmark.circle.fill"
        case "CANCELED": "slash.circle"
        case "RUNNING": "arrow.triangle.2.circlepath.circle.fill"
        case "PENDING", "PREPARING", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK", "SCHEDULED": "clock"
        case "MANUAL": "hand.raised.circle"
        case "SKIPPED": "arrow.right.circle"
        default: "circle.dashed"
        }
    }

    static func tint(_ status: String, allowFailure: Bool = false) -> Color {
        switch status {
        case "SUCCESS": .green
        case "FAILED": allowFailure ? .orange : .red
        case "CANCELED": .red
        case "RUNNING", "PENDING", "PREPARING", "WAITING_FOR_RESOURCE", "WAITING_FOR_CALLBACK", "SCHEDULED": .blue
        default: .gray
        }
    }

    /// A stage's colour and how much of its segment is filled: red once a job that may not fail
    /// failed, blue while a job runs or waits, green once all ran, grey before anything started.
    static func stage(_ stage: PipelineStage) -> (tint: Color, filled: CGFloat) {
        let jobs = stage.jobs
        let counted = jobs.filter { $0.isDone || $0.isActive }
        let filled = counted.isEmpty ? 0 : CGFloat(counted.filter(\.isDone).count) / CGFloat(counted.count)
        if jobs.contains(where: { $0.status == "FAILED" && !$0.allowFailure }) { return (.red, filled) }
        if jobs.contains(where: { $0.status == "CANCELED" }) { return (.red, filled) }
        if jobs.contains(where: \.isActive) { return (.blue, filled) }
        if !counted.isEmpty { return (.green, 1) }
        return (.gray, 0)
    }

    static func duration(from start: Date, to end: Date) -> String {
        Duration.seconds(max(end.timeIntervalSince(start), 0))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
