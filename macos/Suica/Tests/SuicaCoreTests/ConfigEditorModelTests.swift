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
