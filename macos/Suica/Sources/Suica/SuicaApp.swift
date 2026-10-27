import AppKit
import SuicaCore
import SwiftUI

/// Used when the bundle does not name the CLI (for example `swift run`): every call reports unreachable.
private struct UnconfiguredClient: AgentClient {
    func state() async throws(AgentError) -> AgentState { throw AgentError.launchFailed }
    func send(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func skip(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func retry(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func clear(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func clearRecent(_ group: MessageGroup?) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func setPaused(_ paused: Bool) async throws(AgentError) { throw AgentError.launchFailed }
}

extension UnconfiguredClient: DashboardClient {
    func status() async throws(AgentError) -> StatusDocument { throw AgentError.launchFailed }
    func stats() async throws(AgentError) -> StatsDocument { throw AgentError.launchFailed }
    func usage() async throws(AgentError) -> UsageDocument { throw AgentError.launchFailed }
    func config() async throws(AgentError) -> ConfigDocument { throw AgentError.launchFailed }
    func saveConfig(base: String?, edits: [ConfigEditRequest]) async throws(AgentError) -> SaveResult {
        throw AgentError.launchFailed
    }
    func restartAgent() async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
}

extension UnconfiguredClient: ReviewsClient {
    func reviews() async throws(AgentError) -> ReviewListDocument { throw AgentError.launchFailed }
    func mergeRequest(key: String) async throws(AgentError) -> MergeRequestDetail { throw AgentError.launchFailed }
    func queueAgentReview(key: String, choice: ReviewChoice) async throws(AgentError) -> ActionResult {
        throw AgentError.launchFailed
    }
    func reviewOptions(cli: String?) async throws(AgentError) -> ReviewOptions { throw AgentError.launchFailed }
    func postAgentReview(id: Int, inline: Bool) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func discardAgentReview(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func cancelAgentReview(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func approve(key: String, sha: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func teamsMessage(key: String, request: TeamsMessageRequest) async throws(AgentError) -> TeamsMessageReply {
        throw AgentError.launchFailed
    }
}

extension UnconfiguredClient: FixesClient {
    func fixes() async throws(AgentError) -> FixListDocument { throw AgentError.launchFailed }
    func queueFix(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func queuePipelineFix(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func setWatched(key: String, watched: Bool) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func confirmFix(id: Int, edits: ConfirmEdits) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func retryFix(id: Int, note: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func discardFix(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func cancelFix(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func postMissingReplies(id: Int) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func comment(key: String, body: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
    func merge(key: String, sha: String, choice: MergeChoice) async throws(AgentError) -> ActionResult {
        throw AgentError.launchFailed
    }
    func close(key: String) async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
}

extension UnconfiguredClient: OfficeClient {
    func office() async throws(AgentError) -> OfficeDocument { throw AgentError.launchFailed }
    func chat(agent: String, sessionId: String) async throws(AgentError) -> OfficeChatDocument {
        throw AgentError.launchFailed
    }
    func send(agent: String, sessionId: String, message: String) async throws(AgentError) -> ActionResult {
        throw AgentError.launchFailed
    }
}

extension UnconfiguredClient: SetupClient {
    func checkGitlab(host: String) async throws(AgentError) -> GitlabCheck { throw AgentError.launchFailed }
    func installAgent() async throws(AgentError) -> ActionResult { throw AgentError.launchFailed }
}

extension UnconfiguredClient: LessonsClient {
    func lessons() async throws(AgentError) -> LessonListDocument { throw AgentError.launchFailed }
    func lesson(id: Int) async throws(AgentError) -> LessonDetailDocument? { throw AgentError.launchFailed }
    func archiveLesson(id: Int) async throws(AgentError) -> LessonChangeOutcome { throw AgentError.launchFailed }
    func mergeLessons(keep: Int, gone: Int) async throws(AgentError) -> LessonChangeOutcome {
        throw AgentError.launchFailed
    }
    func lessonsStatus() async throws(AgentError) -> LessonsSetupStatus { throw AgentError.launchFailed }
    func installLessons(confirm: Bool) async throws(AgentError) -> LessonsInstallReply { throw AgentError.launchFailed }
    func uninstallLessons() async throws(AgentError) -> LessonsUninstallReply { throw AgentError.launchFailed }
    func exportLessons() async throws(AgentError) -> LessonsExportReply { throw AgentError.launchFailed }
}

extension UnconfiguredClient: TemplatesClient {
    func templates() async throws(AgentError) -> TemplatesDocument { throw AgentError.launchFailed }
    func saveTemplate(name: String, text: String?) async throws(AgentError) -> TemplateSaveResult {
        throw AgentError.launchFailed
    }
}

private let refreshInterval: Duration = .seconds(30)

/// Receives `suica://` links. SwiftUI would open them by building the window's content again, so the
/// window scene turns that off (`handlesExternalEvents`) and the links come here instead.
@MainActor
final class LinkDelegate: NSObject, NSApplicationDelegate {
    /// Set when the app starts, before the system can deliver the link that launched it.
    static var window: WindowModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        if let link = urls.compactMap(DeepLink.init(url:)).last { Self.window?.receive(link) }
    }
}

/// Opens the window for each link received. It sits on the menu bar label, the one view that exists
/// from launch to quit: the window's own scene is gone while the window is closed.
private struct OpenWindowOnLink: ViewModifier {
    let window: WindowModel
    @Environment(\.openWindow) private var openWindow
    @State private var handled = 0

    func body(content: Content) -> some View {
        content.onChange(of: window.linksReceived, initial: true) { _, count in
            guard count > handled else { return }
            handled = count
            // As Open Suica… does: the window sets the Dock icon up when it appears.
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

@main
struct SuicaApp: App {
    @NSApplicationDelegateAdaptor(LinkDelegate.self) private var linkDelegate
    @State private var model: MenuModel
    @State private var window: WindowModel
    @State private var editor: ConfigEditorModel
    @State private var reviews: ReviewsModel
    @State private var fixes: FixesModel
    @State private var templates: TemplateEditorModel
    @State private var office: OfficeModel
    @State private var onboarding: OnboardingModel
    @State private var lessons: LessonsModel
    @State private var plans = PlansModel(store: UserDefaults.standard)
    @State private var appearance = AppearanceSettings()
    @State private var navigator = Navigator()
    @State private var celebrations = CelebrationCounter()

    init() {
        let agent: any AgentClient
        let dashboard: any DashboardClient
        let reviewsClient: any ReviewsClient
        let fixesClient: any FixesClient
        let templatesClient: any TemplatesClient
        let officeClient: any OfficeClient
        let setupClient: any SetupClient
        let lessonsClient: any LessonsClient
        if let config = AgentConfig.fromBundle(.main) {
            let client = CLIAgentClient(config: config, runner: ProcessRunner())
            agent = client
            dashboard = client
            reviewsClient = client
            fixesClient = client
            templatesClient = client
            officeClient = client
            setupClient = client
            lessonsClient = client
        } else {
            agent = UnconfiguredClient()
            dashboard = UnconfiguredClient()
            reviewsClient = UnconfiguredClient()
            fixesClient = UnconfiguredClient()
            templatesClient = UnconfiguredClient()
            officeClient = UnconfiguredClient()
            setupClient = UnconfiguredClient()
            lessonsClient = UnconfiguredClient()
        }
        let model = MenuModel(client: agent)
        _model = State(initialValue: model)
        // The window reuses the popover's model, so an action started in one blocks the other.
        let window = WindowModel(client: dashboard, menu: model)
        _window = State(initialValue: window)
        LinkDelegate.window = window
        _editor = State(initialValue: ConfigEditorModel(client: dashboard))
        _fixes = State(initialValue: FixesModel(client: fixesClient))
        _templates = State(initialValue: TemplateEditorModel(client: templatesClient))
        _office = State(initialValue: OfficeModel(client: officeClient))
        _lessons = State(initialValue: LessonsModel(client: lessonsClient))
        let onboardingModel = OnboardingModel(dashboard: dashboard, setup: setupClient)
        _onboarding = State(initialValue: onboardingModel)
        let reviewsModel = ReviewsModel(client: reviewsClient)
        _reviews = State(initialValue: reviewsModel)
        Task { @MainActor in
            await onboardingModel.checkNeeded()
            // Opening the app runs the re-reviews that only wait for a push to settle.
            if !onboardingModel.needsSetup { await reviewsModel.runWaitingRereviews() }
        }
        Task { @MainActor in await model.runRefreshLoop(every: refreshInterval) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(
                model: model, window: window, reviews: reviews, settings: appearance, navigator: navigator,
                onboarding: onboarding)
                .modifier(Celebrations(model: model, reviews: reviews, settings: appearance, counter: celebrations))
                .appearance(appearance)
        } label: {
            MenuBarIconView(icon: appearance.menuBarIcon, emoji: appearance.menuBarEmoji)
                .modifier(OpenWindowOnLink(window: window))
            if let badge = appearance.menuBarBadge.label(for: model.badgeCount) { Text(badge) }
        }
        .menuBarExtraStyle(.window)

        Window(Copy.appName, id: "main") {
            MainWindow(
                window: window, editor: editor, reviews: reviews, fixes: fixes, templates: templates,
                office: office, lessons: lessons, plans: plans, onboarding: onboarding, settings: appearance, navigator: navigator
            )
            .modifier(Celebrations(model: model, reviews: reviews, settings: appearance, counter: celebrations))
            .appearance(appearance)
        }
        .defaultSize(width: 1100, height: 720)
        .handlesExternalEvents(matching: [])
        .commands {
            SidebarCommands()
            NavigationCommands(navigator: navigator)
        }
    }
}

/// Confetti and sound for a message sent, an MR approved and inbox zero, in the popover and the
/// window alike; Appearance's Try it reaches the counter through the environment.
private struct Celebrations: ViewModifier {
    let model: MenuModel
    let reviews: ReviewsModel
    let settings: AppearanceSettings
    let counter: CelebrationCounter

    func body(content: Content) -> some View {
        content
            .celebrating(settings, trigger: model.sentCount + reviews.approvedCount + counter.value)
            .onChange(of: model.badgeCount, initial: true) { _, count in counter.badgeChanged(to: count) }
            .environment(counter)
    }
}
