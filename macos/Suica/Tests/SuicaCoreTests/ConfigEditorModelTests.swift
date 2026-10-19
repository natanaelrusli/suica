import Foundation
import Testing

@testable import SuicaCore

func makeField(
    _ path: [String], type: FieldType = .int, value: JSONValue = .null, effective: JSONValue = .null
) -> ConfigField {
    ConfigField(
        path: path, type: type, label: path.last ?? "", help: "", options: nil, placeholder: nil,
        restartNote: nil, value: value, effective: effective)
}

func makeConfig(sha: String? = "abc", fields: [ConfigField]? = nil, issues: [ConfigIssue] = []) -> ConfigDocument {
    ConfigDocument(
        version: 1, path: "/c.yaml", exists: sha != nil, sha256: sha, issues: issues,
        fields: fields ?? [
            makeField(["polling", "activeSeconds"], value: .int(30), effective: .int(30)),
            makeField(["polling", "idleSeconds"], value: .null, effective: .int(300)),
            makeField(["teams", "enabled"], type: .bool, value: .null, effective: .null),
        ])
}

@MainActor func loadedEditor(
    _ client: FakeDashboardClient = FakeDashboardClient()
) async -> ConfigEditorModel {
    let model = ConfigEditorModel(client: client)
    await model.load()
    return model
}

@MainActor @Test func loadStoresTheDocumentAndAFailedReloadKeepsIt() async {
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    #expect(model.document == makeConfig())
    await client.setConfigs([.failure(.timedOut)])
    await model.load()
    #expect(model.document == makeConfig())
    #expect(model.banner == Copy.agentTimedOut)
}

@MainActor @Test func valueFallsBackFromDraftToEffectiveToFileValue() async {
    let model = await loadedEditor()
    let active = makeConfig().fields[0]
    let idle = makeConfig().fields[1]
    let enabled = makeConfig().fields[2]
    // No draft: effective when not null.
    #expect(model.value(of: active) == .int(30))
    #expect(model.value(of: idle) == .int(300))
    // Effective null: the file value (also null here).
    #expect(model.value(of: enabled) == .null)
    let fileOnly = makeField(["a"], value: .string("file"), effective: .null)
    #expect(model.value(of: fileOnly) == .string("file"))
    // A draft wins, including an explicit null.
    model.set(active, .int(45))
    #expect(model.value(of: active) == .int(45))
    #expect(model.drafts["polling.activeSeconds"] == .int(45))
    model.resetToDefault(active)
    #expect(model.value(of: active) == .null)
}

@MainActor @Test func isDirtyIsFalseAgainWhenAFieldIsSetBackToItsOriginalValue() async {
    let model = await loadedEditor()
    let active = makeConfig().fields[0]
    #expect(!model.isDirty)
    model.set(active, .int(45))
    #expect(model.isDirty)
    model.set(active, .int(30))
    #expect(!model.isDirty)
    model.set(active, .int(45))
    model.discard()
    #expect(!model.isDirty)
    #expect(model.drafts.isEmpty)
}

@MainActor @Test func usingTheDefaultOnAKeyThatIsAbsentFromTheFileIsNotAChange() async {
    let model = await loadedEditor()
    let idle = makeConfig().fields[1]
    model.resetToDefault(idle)
    #expect(!model.isDirty)
}

@MainActor @Test func resetToDefaultSendsNull() async {
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let active = makeConfig().fields[0]
    model.resetToDefault(active)
    #expect(model.isDirty)
    await model.save()
    let calls = await client.saveCalls
    #expect(calls.count == 1)
    #expect(calls.first?.edits == [ConfigEditRequest(path: ["polling", "activeSeconds"], value: .null)])
}

@MainActor @Test func saveSendsOnlyDirtyFieldsWithTheBaseShaAndClearsDraftsOnSuccess() async {
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let fields = makeConfig().fields
    model.set(fields[0], .int(45))
    model.set(fields[1], .int(300))  // same as the effective value: not a change
    model.set(fields[2], .bool(true))
    #expect(!model.restartSuggested)
    await model.save()
    let calls = await client.saveCalls
    #expect(calls.count == 1)
    #expect(calls.first?.base == "abc")
    #expect(
        calls.first?.edits == [
            ConfigEditRequest(path: ["polling", "activeSeconds"], value: .int(45)),
            ConfigEditRequest(path: ["teams", "enabled"], value: .bool(true)),
        ])
    #expect(model.drafts.isEmpty)
    #expect(model.fieldIssues.isEmpty)
    #expect(model.restartSuggested)
    #expect(!model.saving)
    #expect(await client.configCalls == 2)
}

@MainActor @Test func invalidMapsIssuesToFields() async {
    let client = FakeDashboardClient()
    await client.setSave(
        .success(
            SaveResult(
                status: "invalid",
                issues: [ConfigIssue(path: "polling.activeSeconds", message: "Must be at least 10.")],
                sha256: nil)))
    let model = await loadedEditor(client)
    let active = makeConfig().fields[0]
    model.set(active, .int(1))
    await model.save()
    #expect(model.fieldIssues == ["polling.activeSeconds": "Must be at least 10."])
    #expect(model.isDirty)
    #expect(model.drafts["polling.activeSeconds"] == .int(1))
    #expect(!model.restartSuggested)
    // Editing the field clears its message.
    model.set(active, .int(20))
    #expect(model.fieldIssues.isEmpty)
}

@MainActor @Test func conflictKeepsDrafts() async {
    let client = FakeDashboardClient()
    await client.setSave(.success(SaveResult(status: "conflict", issues: [], sha256: nil)))
    let model = await loadedEditor(client)
    model.set(makeConfig().fields[0], .int(45))
    await model.save()
    #expect(model.banner == Copy.configConflict)
    #expect(model.isDirty)
    #expect(!model.restartSuggested)
    #expect(await client.configCalls == 1)
}

@MainActor @Test func badRequestShowsTheRebuildMessage() async {
    let client = FakeDashboardClient()
    await client.setSave(.success(SaveResult(status: "bad-request", issues: [], sha256: nil)))
    let model = await loadedEditor(client)
    model.set(makeConfig().fields[0], .int(45))
    await model.save()
    #expect(model.banner == Copy.configBadRequest)
    #expect(model.isDirty)
}

@MainActor @Test func aFailedSaveShowsAPlainMessageAndKeepsTheDrafts() async {
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let active = makeConfig().fields[0]
    let cases: [(AgentError, String)] = [
        (.badOutput, Copy.configSaveFailed), (.failed(exitCode: 1), Copy.configSaveFailed),
        (.timedOut, Copy.agentTimedOut), (.launchFailed, Copy.agentUnreachable),
    ]
    for (error, text) in cases {
        await client.setSave(.failure(error))
        model.set(active, .int(45))
        await model.save()
        #expect(model.banner == text)
        #expect(model.drafts["polling.activeSeconds"] == .int(45))
        #expect(model.isDirty)
        #expect(!model.saving)
        #expect(!model.restartSuggested)
    }
}

@MainActor @Test func saveIsIgnoredWhenNotDirtyOrWhileSaving() async {
    let gate = Gate()
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    await model.save()
    #expect(await client.saveCalls.isEmpty)
    await client.setSave(.success(SaveResult(status: "saved", issues: [], sha256: "new")), gate: gate)
    model.set(makeConfig().fields[0], .int(45))
    let first = Task { await model.save() }
    while !model.saving { await Task.yield() }
    await model.save()
    #expect(await client.saveCalls.count == 1)
    await gate.open()
    await first.value
    #expect(!model.saving)
    #expect(await client.saveCalls.count == 1)
}

@MainActor @Test func editsMadeWhileASaveIsInFlightSurviveASuccessfulSave() async {
    let gate = Gate()
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let fields = makeConfig().fields
    await client.setSave(.success(SaveResult(status: "saved", issues: [], sha256: "new")), gate: gate)
    model.set(fields[0], .int(45))
    model.set(fields[2], .bool(true))
    let save = Task { await model.save() }
    while !model.saving { await Task.yield() }
    model.set(fields[0], .int(50))  // a newer value for a field that was sent
    model.set(fields[1], .int(400))  // a field that was not sent
    await gate.open()
    await save.value
    #expect(model.drafts == ["polling.activeSeconds": .int(50), "polling.idleSeconds": .int(400)])
    #expect(model.isDirty)
    #expect(model.restartSuggested)
    #expect(!model.saving)
}

@MainActor @Test func aSavedDraftThatWasNotChangedDuringTheSaveIsCleared() async {
    let gate = Gate()
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let fields = makeConfig().fields
    await client.setSave(.success(SaveResult(status: "saved", issues: [], sha256: "new")), gate: gate)
    model.set(fields[0], .int(45))
    let save = Task { await model.save() }
    while !model.saving { await Task.yield() }
    model.set(fields[0], .int(45))  // the same value again is still the sent value
    await gate.open()
    await save.value
    #expect(model.drafts.isEmpty)
    #expect(!model.isDirty)
}

@MainActor @Test func anIssueOnAPathThatIsNotAFormFieldShowsInTheBanner() async {
    let client = FakeDashboardClient()
    await client.setSave(
        .success(
            SaveResult(
                status: "invalid",
                issues: [
                    ConfigIssue(path: "polling.activeSeconds", message: "Must be at least 10."),
                    ConfigIssue(path: "teams.workingHours", message: "start is after\nend"),
                    ConfigIssue(path: "(root)", message: "unknown key"),
                ], sha256: nil)))
    let model = await loadedEditor(client)
    model.set(makeConfig().fields[0], .int(1))
    await model.save()
    #expect(model.fieldIssues["polling.activeSeconds"] == "Must be at least 10.")
    #expect(
        model.banner
            == "\(Copy.configInvalid) teams.workingHours: start is after end; (root): unknown key")
    #expect(model.isDirty)
}

@MainActor @Test func anInvalidResultWithoutIssuesStillSaysNothingWasSaved() async {
    let client = FakeDashboardClient()
    await client.setSave(.success(SaveResult(status: "invalid", issues: [], sha256: nil)))
    let model = await loadedEditor(client)
    model.set(makeConfig().fields[0], .int(1))
    await model.save()
    #expect(model.banner == Copy.configInvalid)
    #expect(Copy.configInvalid == "The config has problems. Nothing was saved.")
    #expect(model.isDirty)
}

@MainActor @Test func issuesOnlyOnFormFieldsDoNotSetABanner() async {
    let client = FakeDashboardClient()
    await client.setSave(
        .success(
            SaveResult(
                status: "invalid", issues: [ConfigIssue(path: "polling.activeSeconds", message: "Bad.")],
                sha256: nil)))
    let model = await loadedEditor(client)
    model.set(makeConfig().fields[0], .int(1))
    await model.save()
    #expect(model.banner == nil)
}

@MainActor @Test func restartHandledClearsTheSuggestion() async {
    let model = await loadedEditor()
    model.set(makeConfig().fields[0], .int(45))
    await model.save()
    #expect(model.restartSuggested)
    model.restartHandled()
    #expect(!model.restartSuggested)
}

@MainActor @Test func invalidInputBlocksSavingUntilItIsCleared() async {
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let active = makeConfig().fields[0]
    model.set(active, .int(3))
    #expect(model.canSave)
    model.setInputInvalid(active, true)
    #expect(model.invalidInputKeys == ["polling.activeSeconds"])
    #expect(!model.canSave)
    await model.save()
    #expect(await client.saveCalls.isEmpty)
    model.setInputInvalid(active, false)
    #expect(model.invalidInputKeys.isEmpty)
    #expect(model.canSave)
    await model.save()
    #expect(await client.saveCalls.count == 1)
}

@MainActor @Test func invalidInputIsClearedByDiscardSetAndResetOfThatField() async {
    let model = await loadedEditor()
    let fields = makeConfig().fields
    model.setInputInvalid(fields[0], true)
    model.setInputInvalid(fields[1], true)
    model.discard()
    #expect(model.invalidInputKeys.isEmpty)
    model.setInputInvalid(fields[0], true)
    model.set(fields[0], .int(45))
    #expect(model.invalidInputKeys.isEmpty)
    model.setInputInvalid(fields[0], true)
    model.resetToDefault(fields[0])
    #expect(model.invalidInputKeys.isEmpty)
}

@MainActor @Test func invalidInputBlocksSavingEvenWithoutADraftChange() async {
    let model = await loadedEditor()
    let fields = makeConfig().fields
    model.setInputInvalid(fields[0], true)
    #expect(!model.isDirty)
    #expect(!model.canSave)
}

@MainActor @Test func aDocumentWithANewHashClearsInvalidInputButTheSameHashKeepsIt() async {
    let client = FakeDashboardClient()
    let model = await loadedEditor(client)
    let active = makeConfig().fields[0]
    model.setInputInvalid(active, true)
    await model.load()
    #expect(!model.invalidInputKeys.isEmpty)
    await client.setConfigs([.success(makeConfig(sha: "def"))])
    await model.load()
    #expect(model.invalidInputKeys.isEmpty)
}

@MainActor @Test func clearInputInvalidReEnablesSavingAndKeepsTheDrafts() async {
    let model = await loadedEditor()
    let fields = makeConfig().fields
    model.set(fields[0], .int(45))
    model.setInputInvalid(fields[0], true)
    model.setInputInvalid(fields[1], true)
    #expect(!model.canSave)
    model.clearInputInvalid()
    #expect(model.invalidInputKeys.isEmpty)
    #expect(model.drafts["polling.activeSeconds"] == .int(45))
    #expect(model.canSave)
}

@MainActor @Test func clearingAnOptionalTextBoxRemovesTheKey() async {
    let command = makeField(["teams", "command"], type: .string, value: .string("/run.sh"))
    let state = makeField(["statePath"], type: .string, value: .string("/s.db"))
    let host = makeField(["gitlab", "hostname"], type: .string, value: .string("h"), effective: .string("h"))
    let model = await loadedEditor(FakeDashboardClient(configs: [.success(makeConfig(fields: [command, state, host]))]))
    model.setText(command, "")
    model.setText(state, "/other.db")
    model.setText(host, "")
    #expect(model.drafts["teams.command"] == .null)
    #expect(model.drafts["statePath"] == .string("/other.db"))
    // A required field keeps the empty text: the agent reports the issue next to it.
    #expect(model.drafts["gitlab.hostname"] == .string(""))
    model.setText(state, "")
    #expect(model.drafts["statePath"] == .null)
}

@MainActor @Test func aFieldShowsTheLoadedIssueUntilItIsEditedAndASaveIssueWins() async {
    let active = makeField(["polling", "activeSeconds"], value: .number(1.5))
    let issues = [ConfigIssue(path: "polling.activeSeconds", message: "Expected integer, received float")]
    let client = FakeDashboardClient(configs: [.success(makeConfig(fields: [active], issues: issues))])
    let model = await loadedEditor(client)
    #expect(model.value(of: active) == .number(1.5))
    #expect(model.issue(of: active) == "Expected integer, received float")
    model.set(active, .int(2))
    #expect(model.issue(of: active) == nil)
    await client.setSave(
        .success(SaveResult(status: "invalid", issues: [ConfigIssue(path: "polling.activeSeconds", message: "too big")], sha256: nil)))
    await model.save()
    #expect(model.issue(of: active) == "too big")
}

@MainActor @Test func searchMatchesEveryWordAndKeepsFieldsThatNeedAttention() async {
    let model = await loadedEditor()
    let active = makeConfig().fields[0]
    let idle = makeConfig().fields[1]
    let enabled = makeConfig().fields[2]
    #expect(model.isShown(enabled, query: "  "))
    #expect(model.isShown(enabled, query: "TEAMS enab"))
    #expect(!model.isShown(enabled, query: "teams polling"))
    #expect(model.isShown(idle, query: "polling.idle"))
    #expect(!model.isShown(active, query: "teams"))
    model.set(active, .int(45))
    #expect(model.isShown(active, query: "teams"))
    model.setInputInvalid(idle, true)
    #expect(model.isShown(idle, query: "teams"))
}
