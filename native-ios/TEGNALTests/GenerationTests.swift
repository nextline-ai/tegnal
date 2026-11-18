import XCTest
@testable import TEGNAL

/// A scripted stand-in for the generation service that remembers every request it was given.
private final class Wire: @unchecked Sendable {
    struct Reply {
        var status = 200
        var json: Any?
        var data: Data?
        var headers: [String: String] = [:]
    }
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> Reply

    /// `handler` receives the request and its 1-based position among all requests.
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) { self.handler = handler }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }

    var transport: GenerationClient.Transport {
        { [self] request in
            lock.lock(); log.append(request); let position = log.count; lock.unlock()
            let reply = handler(request, position)
            let data = reply.data ?? reply.json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            return (data, response)
        }
    }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func add(_ value: Value) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return stored }
}

private let testCheckpoint = "urn:air:sdxl:checkpoint:civitai:827184@2514310"
private let testPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
private let testJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

private func jobJSON(id: String = "wf_1", status: String = "succeeded", cost: Double = 8, images: [[String: Any]]? = nil, jobs: [[String: Any]] = []) -> [String: Any] {
    let pictures = images ?? [["id": "img1", "url": "https://pictures.test/a.png", "width": 832, "height": 1216, "available": true]]
    return ["id": id, "status": status, "cost": ["total": cost], "steps": [["output": ["images": pictures], "jobs": jobs]]]
}

@MainActor
final class GenerationTests: XCTestCase {

    // MARK: Helpers

    private func settings(air: String? = testCheckpoint) -> GenerationSettings {
        var settings = GenerationSettings()
        if let air { settings.model = GenerationModel(air: air, name: "Model") }
        return settings
    }

    private func makeDefaults() -> UserDefaults {
        let name = "generation-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("generation-tests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func makeStore(defaults: UserDefaults? = nil, folder: URL? = nil, key: String = "",
                           saveKey: @escaping (String) -> Bool = { _ in true }, transport: GenerationClient.Transport? = nil) -> GenerationStore {
        GenerationStore(folder: folder ?? makeFolder(), defaults: defaults ?? makeDefaults(), key: key, saveKey: saveKey, transport: transport)
    }

    private func input(of request: URLRequest, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody, file: file, line: line)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any], file: file, line: line)
        let steps = try XCTUnwrap(object["steps"] as? [[String: Any]], file: file, line: line)
        return try XCTUnwrap(steps.first?["input"] as? [String: Any], file: file, line: line)
    }

    private func topLevel(of request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func queryItems(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private func assertThrows<T>(_ expected: GenerationError, _ block: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await block(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? GenerationError, expected, file: file, line: line) }
    }

    private func detail(_ error: GenerationError?) -> String? {
        if case .failed(let text) = error { return text }
        return nil
    }

    // MARK: AIR

    func testAIRParsesTheFullFormWithAllParts() throws {
        let air = try XCTUnwrap(GenerationAIR("urn:air:sdxl:lora:civitai:123@456+model.safetensors"))
        XCTAssertEqual(air.ecosystem, "sdxl")
        XCTAssertEqual(air.type, "lora")
        XCTAssertEqual(air.source, "civitai")
        XCTAssertEqual(air.id, "123")
        XCTAssertEqual(air.version, "456")
        XCTAssertEqual(air.file, "model")
        XCTAssertEqual(air.format, "safetensors")
    }

    func testAIRParsesWithoutThePrefixesAndWithSurroundingWhitespace() throws {
        let air = try XCTUnwrap(GenerationAIR("  sdxl:checkpoint:civitai:827184@2514310\n"))
        XCTAssertEqual(air.ecosystem, "sdxl")
        XCTAssertEqual(air.type, "checkpoint")
        XCTAssertEqual(air.source, "civitai")
        XCTAssertEqual(air.id, "827184")
        XCTAssertEqual(air.version, "2514310")
        XCTAssertNil(air.file)
        XCTAssertNil(air.format)
        let onlyAir = try XCTUnwrap(GenerationAIR("air:sdxl:checkpoint:civitai:1"))
        XCTAssertEqual(onlyAir.type, "checkpoint")
    }

    func testAIRAcceptsTheThreeAndTwoPartForms() throws {
        let three = try XCTUnwrap(GenerationAIR("sdxl:civitai:99"))
        XCTAssertEqual(three.ecosystem, "sdxl")
        XCTAssertNil(three.type)
        XCTAssertEqual(three.source, "civitai")
        XCTAssertEqual(three.id, "99")
        let two = try XCTUnwrap(GenerationAIR("civitai:99"))
        XCTAssertNil(two.ecosystem)
        XCTAssertNil(two.type)
        XCTAssertEqual(two.source, "civitai")
        XCTAssertEqual(two.id, "99")
        XCTAssertNil(two.version)
    }

    func testAIRParsesVersionFileAndFormatSeparately() throws {
        let versionOnly = try XCTUnwrap(GenerationAIR("civitai:1@2"))
        XCTAssertEqual(versionOnly.version, "2")
        XCTAssertNil(versionOnly.file)
        XCTAssertNil(versionOnly.format)
        let withFile = try XCTUnwrap(GenerationAIR("civitai:1@2+weights"))
        XCTAssertEqual(withFile.version, "2")
        XCTAssertEqual(withFile.file, "weights")
        let withFormat = try XCTUnwrap(GenerationAIR("civitai:1@2.safetensors"))
        XCTAssertEqual(withFormat.version, "2")
        XCTAssertEqual(withFormat.format, "safetensors")
        XCTAssertNil(withFormat.file)
    }

    func testAIRKeepsEcosystemAndTypeInLowercase() throws {
        let air = try XCTUnwrap(GenerationAIR("SDXL:Checkpoint:civitai:1"))
        XCTAssertEqual(air.ecosystem, "sdxl")
        XCTAssertEqual(air.type, "checkpoint")
        XCTAssertEqual(air.kind, .checkpoint)
    }

    func testAIRRoundTripsThroughItsText() throws {
        for original in ["urn:air:sdxl:checkpoint:civitai:827184@2514310",
                         "urn:air:sdxl:lora:civitai:123@456+model.safetensors",
                         "sdxl:civitai:7", "civitai:7", "air:sd1:embedding:civitai:5@6"] {
            let air = try XCTUnwrap(GenerationAIR(original), original)
            let again = try XCTUnwrap(GenerationAIR(air.text), air.text)
            XCTAssertEqual(again, air, original)
            XCTAssertEqual(again.text, air.text, original)
            XCTAssertTrue(air.text.hasPrefix("urn:air:"), "The text is always the full form")
        }
        XCTAssertEqual(GenerationAIR("urn:air:sdxl:checkpoint:civitai:827184@2514310")?.text, "urn:air:sdxl:checkpoint:civitai:827184@2514310")
        XCTAssertEqual(GenerationAIR("civitai:7")?.text, "urn:air:civitai:7")
    }

    func testAIRRejectsEmptyGarbageSpacesAndTooManyParts() {
        for text in ["", "   ", "garbage", "urn:air:", "civitai:", ":123", "civi tai:123", "civitai:12 3", "sdxl:check point:civitai:1",
                     "!!!:???", "urn:air:a:b:c:d:e", "a:b:c:d:e", "civitai:1@", "civitai:1@2+", "civitai:1@bad value"] {
            XCTAssertNil(GenerationAIR(text), "\"\(text)\" is not an identifier")
        }
    }

    func testAIRKindMapping() throws {
        func kind(_ text: String) throws -> GenerationAIR.Kind { try XCTUnwrap(GenerationAIR(text), text).kind }
        XCTAssertEqual(try kind("urn:air:sdxl:checkpoint:civitai:1"), .checkpoint)
        XCTAssertEqual(try kind("urn:air:sdxl:lora:civitai:1"), .lora)
        XCTAssertEqual(try kind("urn:air:sdxl:locon:civitai:1"), .lora)
        XCTAssertEqual(try kind("urn:air:sd1:embedding:civitai:1"), .embedding)
        XCTAssertEqual(try kind("urn:air:sd1:textualinversion:civitai:1"), .embedding)
        XCTAssertEqual(try kind("urn:air:sdxl:vae:civitai:1"), .vae)
        XCTAssertEqual(try kind("urn:air:sdxl:controlnet:civitai:1"), .other)
        XCTAssertEqual(try kind("sdxl:civitai:1"), .other, "Without a type there is no kind to name")
    }

    func testAIRFamilyMapping() throws {
        func family(_ ecosystem: String) throws -> GenerationAIR.Family? { try XCTUnwrap(GenerationAIR("urn:air:\(ecosystem):checkpoint:civitai:1")).family }
        XCTAssertEqual(try family("sd1"), .sd1)
        XCTAssertEqual(try family("sd15"), .sd1)
        for sdxl in ["sdxl", "illustrious", "pony", "noobai"] { XCTAssertEqual(try family(sdxl), .sdxl, sdxl) }
        XCTAssertEqual(try family("anima"), .anima)
        XCTAssertNil(try family("flux1"))
        XCTAssertNil(try family("sd3"))
        XCTAssertNil(GenerationAIR("civitai:1")?.family, "No ecosystem, no family")
    }

    func testAnimaIdentifierParsesAndRoundTrips() throws {
        let text = "urn:air:anima:checkpoint:civitai:2458426@2945208+2824391"
        let air = try XCTUnwrap(GenerationAIR(text))
        XCTAssertEqual(air.ecosystem, "anima")
        XCTAssertEqual(air.type, "checkpoint")
        XCTAssertEqual(air.source, "civitai")
        XCTAssertEqual(air.id, "2458426")
        XCTAssertEqual(air.version, "2945208")
        XCTAssertEqual(air.file, "2824391")
        XCTAssertEqual(air.family, .anima)
        XCTAssertEqual(air.kind, .checkpoint)
        XCTAssertEqual(air.text, text)
        XCTAssertEqual(GenerationAIR(air.text), air)
    }

    func testVersionIDFromANumberAPageAddressAnAPIAddressAndGarbage() {
        XCTAssertEqual(GenerationAIR.versionID(in: "2514310"), 2514310)
        XCTAssertEqual(GenerationAIR.versionID(in: "  2514310\n"), 2514310)
        XCTAssertEqual(GenerationAIR.versionID(in: "https://civitai.com/models/827184/some-model?modelVersionId=2514310"), 2514310)
        XCTAssertEqual(GenerationAIR.versionID(in: "https://civitai.com/api/v1/model-versions/123"), 123)
        XCTAssertNil(GenerationAIR.versionID(in: "https://civitai.com/models/827184/some-model"), "A model page without a version names no version")
        XCTAssertNil(GenerationAIR.versionID(in: "hello world"))
        XCTAssertNil(GenerationAIR.versionID(in: ""))
        XCTAssertNil(GenerationAIR.versionID(in: "0"))
        XCTAssertNil(GenerationAIR.versionID(in: "-5"))
        XCTAssertNil(GenerationAIR.versionID(in: "https://civitai.com/api/v1/model-versions/abc"))
        XCTAssertNil(GenerationAIR.versionID(in: "https://civitai.com/api/v1/model-versions"))
    }

    // MARK: Settings

    func testRoughCostFollowsThePublishedFormula() {
        var settings = GenerationSettings()
        settings.width = 1024; settings.height = 1024; settings.steps = 20; settings.quantity = 1
        XCTAssertEqual(settings.roughCost, 8)
        settings.quantity = 4
        XCTAssertEqual(settings.roughCost, 32)
        settings.quantity = 1; settings.steps = 40
        XCTAssertEqual(settings.roughCost, 16)
        XCTAssertEqual(GenerationSettings().roughCost, 10, "832x1216 at 25 steps is 9.65 Buzz, rounded up")
    }

    func testRoughCostDividesStepsBy25ForAnimaAndBy20ForOthers() {
        var anima = GenerationSettings()
        anima.use(.recommended)
        anima.width = 1024; anima.height = 1024; anima.steps = 50; anima.quantity = 1
        XCTAssertEqual(anima.roughCost, 16, "8 x 50 / 25")
        anima.quantity = 3
        XCTAssertEqual(anima.roughCost, 48)
        anima.quantity = 1; anima.steps = 30
        XCTAssertEqual(anima.roughCost, 10, "8 x 30 / 25 = 9.6, rounded up")
        var sdxl = settings()
        sdxl.width = 1024; sdxl.height = 1024; sdxl.steps = 50
        XCTAssertEqual(sdxl.roughCost, 20, "8 x 50 / 20")
    }

    func testSchedulesIncludeSimple() {
        XCTAssertTrue(GenerationSettings.schedules.contains("simple"))
    }

    func testTheRecommendedModelIsAnimaBaseV1() throws {
        let model = GenerationModel.recommended
        XCTAssertEqual(model.air, "urn:air:anima:checkpoint:civitai:2458426@2945208+2824391")
        XCTAssertEqual(model.name, "Anima · base-v1.0")
        XCTAssertEqual(GenerationAIR(model.air)?.family, .anima)
        XCTAssertTrue(model.isRecommended)
    }

    func testIsRecommendedIgnoresTheFilePartButNotTheModelOrVersion() {
        func model(_ air: String) -> GenerationModel { GenerationModel(air: air, name: "M") }
        XCTAssertTrue(model("urn:air:anima:checkpoint:civitai:2458426@2945208").isRecommended, "Without the file part")
        XCTAssertFalse(model("urn:air:anima:checkpoint:civitai:2458426@999").isRecommended, "Another version")
        XCTAssertFalse(model("urn:air:anima:checkpoint:civitai:777@2945208").isRecommended, "Another model")
        XCTAssertFalse(model(testCheckpoint).isRecommended)
        XCTAssertFalse(model("").isRecommended)
        XCTAssertFalse(model("garbage").isRecommended)
    }

    func testStartingSettingsChooseTheRecommendedModelWithAnimaValues() {
        let starting = GenerationSettings.starting
        XCTAssertEqual(starting.model, GenerationModel.recommended)
        XCTAssertEqual(starting.steps, 30)
        XCTAssertEqual(starting.guidance, 4)
        XCTAssertEqual(starting.sampler, "euler")
        XCTAssertEqual(starting.schedule, "simple")
    }

    func testChoosingAnAnimaModelSetsItsValuesAndChoosingSDXLRestoresTheOthers() {
        var settings = GenerationSettings()
        settings.model = GenerationModel(air: testCheckpoint, name: "SDXL")
        settings.use(.recommended)
        XCTAssertEqual(settings.model, GenerationModel.recommended)
        XCTAssertEqual(settings.steps, 30)
        XCTAssertEqual(settings.guidance, 4)
        XCTAssertEqual(settings.sampler, "euler")
        XCTAssertEqual(settings.schedule, "simple")

        settings.use(GenerationModel(air: "urn:air:sdxl:checkpoint:civitai:1@2", name: "SDXL"))
        XCTAssertEqual(settings.steps, 25)
        XCTAssertEqual(settings.guidance, 5.5)
        XCTAssertEqual(settings.sampler, "euler_a")
        XCTAssertEqual(settings.schedule, "discrete")
    }

    func testChoosingAModelOfTheSameFamilyKeepsTheUsersValues() {
        var anima = GenerationSettings.starting
        anima.steps = 40; anima.guidance = 3; anima.sampler = "dpm++2m"; anima.schedule = "karras"
        anima.use(GenerationModel(air: "urn:air:anima:checkpoint:civitai:5@6", name: "Other Anima"))
        XCTAssertEqual(anima.model?.air, "urn:air:anima:checkpoint:civitai:5@6")
        XCTAssertEqual(anima.steps, 40)
        XCTAssertEqual(anima.guidance, 3)
        XCTAssertEqual(anima.sampler, "dpm++2m")
        XCTAssertEqual(anima.schedule, "karras")

        var sdxl = settings()
        sdxl.steps = 33; sdxl.guidance = 7; sdxl.sampler = "lcm"; sdxl.schedule = "karras"
        sdxl.use(GenerationModel(air: "urn:air:illustrious:checkpoint:civitai:9@9", name: "Illustrious"))
        XCTAssertEqual(sdxl.steps, 33)
        XCTAssertEqual(sdxl.guidance, 7)
        XCTAssertEqual(sdxl.sampler, "lcm")
        XCTAssertEqual(sdxl.schedule, "karras")
    }

    // MARK: Request body

    func testBodyHasTheExpectedShape() throws {
        var settings = settings()
        settings.width = 1024; settings.height = 1024; settings.steps = 30; settings.guidance = 6.5
        settings.sampler = "dpm++2m"; settings.schedule = "karras"; settings.quantity = 2; settings.negative = "blurry"
        settings.mature = true
        let body = try GenerationClient.body(prompt: "1girl, smile", settings: settings)
        let step = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first)
        XCTAssertEqual(step["$type"] as? String, "imageGen")
        let input = try XCTUnwrap(step["input"] as? [String: Any])
        XCTAssertEqual(input["engine"] as? String, "sdcpp")
        XCTAssertEqual(input["ecosystem"] as? String, "sdxl")
        XCTAssertEqual(input["operation"] as? String, "createImage")
        XCTAssertEqual(input["model"] as? String, testCheckpoint)
        XCTAssertEqual(input["prompt"] as? String, "1girl, smile")
        XCTAssertEqual(input["negativePrompt"] as? String, "blurry")
        XCTAssertEqual(input["width"] as? Int, 1024)
        XCTAssertEqual(input["height"] as? Int, 1024)
        XCTAssertEqual(input["steps"] as? Int, 30)
        XCTAssertEqual(input["cfgScale"] as? Double, 6.5)
        XCTAssertEqual(input["sampleMethod"] as? String, "dpm++2m")
        XCTAssertEqual(input["schedule"] as? String, "karras")
        XCTAssertEqual(input["quantity"] as? Int, 2)
        XCTAssertNil(input["seed"], "No seed set, so the service draws one")
        XCTAssertNil(input["loras"])
        XCTAssertNil(body["allowMatureContent"], "Left unset when mature results are allowed")
    }

    func testBodyUsesTheEcosystemOfTheModelsFamily() throws {
        let sd1 = try GenerationClient.body(prompt: "x", settings: settings(air: "urn:air:sd15:checkpoint:civitai:4384@128713"))
        XCTAssertEqual((try XCTUnwrap((sd1["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any]))["ecosystem"] as? String, "sd1")
        let illustrious = try GenerationClient.body(prompt: "x", settings: settings(air: "urn:air:illustrious:checkpoint:civitai:1@2"))
        XCTAssertEqual((try XCTUnwrap((illustrious["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any]))["ecosystem"] as? String, "sdxl")
    }

    func testBodyOmitsABlankNegativePromptAndSendsAnExplicitSeed() throws {
        var settings = settings()
        settings.negative = "  \n "
        settings.seed = 1234567890123
        let body = try GenerationClient.body(prompt: "x", settings: settings)
        let input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertNil(input["negativePrompt"])
        XCTAssertEqual((input["seed"] as? NSNumber)?.int64Value, 1234567890123)
    }

    func testBodyDeclinesMatureContentOnlyWhenItIsOff() throws {
        var settings = settings()
        settings.mature = false
        XCTAssertEqual(try GenerationClient.body(prompt: "x", settings: settings)["allowMatureContent"] as? Bool, false)
        settings.mature = true
        XCTAssertNil(try GenerationClient.body(prompt: "x", settings: settings)["allowMatureContent"])
    }

    func testBodyWritesLorasAsAIRToStrengthAndSkipsUnreadableOnes() throws {
        var settings = settings()
        settings.loras = [
            GenerationLora(model: GenerationModel(air: "urn:air:sdxl:lora:civitai:1@2", name: "A"), strength: 0.6),
            GenerationLora(model: GenerationModel(air: "urn:air:sdxl:lora:civitai:3@4", name: "B"), strength: 1.0),
            GenerationLora(model: GenerationModel(air: "not an identifier", name: "C"), strength: 0.5),
            GenerationLora(model: GenerationModel(air: "", name: "D"), strength: 0.5),
        ]
        let input = try XCTUnwrap((try GenerationClient.body(prompt: "x", settings: settings)["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        let loras = try XCTUnwrap(input["loras"] as? [String: Double])
        XCTAssertEqual(loras, ["urn:air:sdxl:lora:civitai:1@2": 0.6, "urn:air:sdxl:lora:civitai:3@4": 1.0])
    }

    func testBodyNamesTheCheckpointFieldAsAsked() throws {
        let body = try GenerationClient.body(prompt: "x", settings: settings(), field: "checkpointModel")
        let input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertEqual(input["checkpointModel"] as? String, testCheckpoint)
        XCTAssertNil(input["model"])
    }

    private func animaSettings(air: String? = nil) -> GenerationSettings {
        var settings = GenerationSettings()
        settings.use(air.map { GenerationModel(air: $0, name: "Anima model") } ?? .recommended)
        return settings
    }

    func testAnimaBodyHasNoCheckpointFieldForTheRecommendedModel() throws {
        let body = try GenerationClient.body(prompt: "1girl", settings: animaSettings())
        let input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertEqual(input["engine"] as? String, "sdcpp")
        XCTAssertEqual(input["ecosystem"] as? String, "anima")
        XCTAssertEqual(input["operation"] as? String, "createImage")
        XCTAssertNil(input["model"])
        XCTAssertNil(input["checkpointModel"])
        XCTAssertNil(input["diffuserModel"])
        XCTAssertEqual(input["steps"] as? Int, 30)
        XCTAssertEqual(input["cfgScale"] as? Double, 4)
        XCTAssertEqual(input["sampleMethod"] as? String, "euler")
        XCTAssertEqual(input["schedule"] as? String, "simple")
        for field in GenerationClient.modelFields {
            let named = try GenerationClient.body(prompt: "x", settings: animaSettings(), field: field)
            let namedInput = try XCTUnwrap((named["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
            XCTAssertNil(namedInput[field], "The field name asked for makes no difference to Anima")
            XCTAssertNil(namedInput["diffuserModel"])
        }
    }

    func testAnimaBodySendsAnotherCheckpointAsDiffuserModel() throws {
        let other = "urn:air:anima:checkpoint:civitai:5@6"
        let body = try GenerationClient.body(prompt: "x", settings: animaSettings(air: other))
        let input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertEqual(input["ecosystem"] as? String, "anima")
        XCTAssertEqual(input["diffuserModel"] as? String, other)
        XCTAssertNil(input["model"])
        XCTAssertNil(input["checkpointModel"])
    }

    func testAnimaBodyCarriesLorasNegativeSeedQuantityAndMatureFlagLikeOthers() throws {
        var settings = animaSettings()
        settings.loras = [GenerationLora(model: GenerationModel(air: "urn:air:anima:lora:civitai:1@2", name: "A"), strength: 0.7),
                          GenerationLora(model: GenerationModel(air: "nonsense", name: "B"), strength: 0.5)]
        settings.negative = "blurry"; settings.seed = 123; settings.quantity = 3
        var body = try GenerationClient.body(prompt: "x", settings: settings)
        var input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertEqual(input["loras"] as? [String: Double], ["urn:air:anima:lora:civitai:1@2": 0.7])
        XCTAssertEqual(input["negativePrompt"] as? String, "blurry")
        XCTAssertEqual((input["seed"] as? NSNumber)?.int64Value, 123)
        XCTAssertEqual(input["quantity"] as? Int, 3)
        XCTAssertEqual(body["allowMatureContent"] as? Bool, false)
        settings.mature = true; settings.negative = " "; settings.seed = nil
        body = try GenerationClient.body(prompt: "x", settings: settings)
        input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertNil(body["allowMatureContent"])
        XCTAssertNil(input["negativePrompt"])
        XCTAssertNil(input["seed"])
    }

    func testSDXLBodyStillSendsTheCheckpointFieldAndNoDiffuserModel() throws {
        let body = try GenerationClient.body(prompt: "x", settings: settings())
        let input = try XCTUnwrap((body["steps"] as? [[String: Any]])?.first?["input"] as? [String: Any])
        XCTAssertEqual(input["model"] as? String, testCheckpoint)
        XCTAssertNil(input["diffuserModel"])
    }

    func testBodyRefusesWithoutAModelAndForModelsItCannotRun() {
        func assert(_ settings: GenerationSettings, _ expected: GenerationError, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try GenerationClient.body(prompt: "x", settings: settings), message, line: line) {
                XCTAssertEqual($0 as? GenerationError, expected, message, line: line)
            }
        }
        assert(settings(air: nil), .noModel, "No model chosen")
        assert(settings(air: ""), .noModel, "A search result not yet looked up has no identifier")
        assert(settings(air: "garbage"), .noModel, "An unreadable identifier")
        assert(settings(air: "urn:air:flux1:checkpoint:civitai:1@2"), .unsupportedModel, "Flux is not an engine this generator runs")
        assert(settings(air: "urn:air:sdxl:lora:civitai:1@2"), .unsupportedModel, "A LoRA cannot be the checkpoint")
        assert(settings(air: "civitai:1"), .unsupportedModel, "Without an ecosystem the engine is unknown")
    }

    // MARK: Requests

    func testSubmitPostsToTheWorkflowsAddressWithTheKeyAndWait() async throws {
        let wire = Wire { _, _ in .init(json: jobJSON()) }
        let client = GenerationClient(key: "  secret-key \n", transport: wire.transport)
        let job = try await client.submit(prompt: "1girl", settings: settings())
        XCTAssertEqual(job.id, "wf_1")
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "orchestration.civitai.com")
        XCTAssertEqual(request.url?.path, "/v2/consumer/workflows")
        XCTAssertEqual(queryItems(request), ["wait": "30"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try input(of: request)["prompt"] as? String, "1girl")
    }

    func testSubmitAcceptsACustomWait() async throws {
        let wire = Wire { _, _ in .init(json: jobJSON()) }
        _ = try await GenerationClient(key: "k", transport: wire.transport).submit(prompt: "x", settings: settings(), wait: 5)
        XCTAssertEqual(queryItems(try XCTUnwrap(wire.requests.first)), ["wait": "5"])
    }

    func testEstimateAsksForADryRunAndReturnsTheCost() async throws {
        let wire = Wire { _, _ in .init(json: ["cost": ["total": 12.5]]) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        let cost = try await client.estimate(prompt: "x", settings: settings())
        XCTAssertEqual(cost, 12.5)
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v2/consumer/workflows")
        XCTAssertEqual(queryItems(request), ["whatif": "true"])
    }

    func testAnEmptyKeyIsRefusedBeforeAnythingIsSent() async {
        let wire = Wire { _, _ in .init(json: jobJSON()) }
        let client = GenerationClient(key: "  \n", transport: wire.transport)
        await assertThrows(.noKey) { try await client.account() }
        await assertThrows(.noKey) { try await client.submit(prompt: "x", settings: self.settings()) }
        await assertThrows(.noKey) { try await client.estimate(prompt: "x", settings: self.settings()) }
        await assertThrows(.noKey) { try await client.job("wf_1") }
        XCTAssertTrue(wire.requests.isEmpty, "Nothing leaves the device without a key")
    }

    func testAccountReadsTheNameAndStatusFromTheSiteAPI() async throws {
        let wire = Wire { _, _ in .init(json: ["username": "alice", "status": "active"]) }
        let account = try await GenerationClient(key: "k1", transport: wire.transport).account()
        XCTAssertEqual(account, GenerationAccount(name: "alice", status: "active"))
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://civitai.com/api/v1/me")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k1")
    }

    func testAnAnswerThatIsNotJSONIsUnreadable() async {
        let wire = Wire { _, _ in .init(data: Data("<html>".utf8)) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        await assertThrows(.unreadable) { try await client.account() }
    }

    func testPictureIsFetchedWithoutTheKey() async throws {
        let wire = Wire { _, _ in .init(data: testPNG) }
        let client = GenerationClient(key: "secret-key", transport: wire.transport)
        let url = URL(string: "https://pictures.test/signed/a.png?sig=1")!
        let data = try await client.picture(url)
        XCTAssertEqual(data, testPNG)
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.url, url)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "A signed address needs no key, and must not get it")
    }

    func testPictureFailsOnAnErrorOrEmptyAnswer() async {
        let empty = Wire { _, _ in .init(data: Data()) }
        await assertThrows(.failed("")) { try await GenerationClient(key: "k", transport: empty.transport).picture(URL(string: "https://pictures.test/a.png")!) }
        let missing = Wire { _, _ in .init(status: 404, data: Data("x".utf8)) }
        await assertThrows(.failed("")) { try await GenerationClient(key: "k", transport: missing.transport).picture(URL(string: "https://pictures.test/a.png")!) }
    }

    func testPictureNeedsNoKeyAtAll() async throws {
        let wire = Wire { _, _ in .init(data: testJPEG) }
        let data = try await GenerationClient(key: "", transport: wire.transport).picture(URL(string: "https://pictures.test/a.jpg")!)
        XCTAssertEqual(data, testJPEG)
    }

    func testJobAsksForAWorkflowByIdAndCancelDeletesIt() async throws {
        let wire = Wire { _, _ in .init(json: jobJSON(id: "wf_9", status: "processing")) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        let job = try await client.job("wf_9")
        XCTAssertEqual(job.status, "processing")
        var request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v2/consumer/workflows/wf_9")
        XCTAssertEqual(queryItems(request), ["wait": "30"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        await client.cancel("wf_9")
        request = try XCTUnwrap(wire.requests.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v2/consumer/workflows/wf_9")
    }

    // MARK: Model field fallback

    func testARefusedSubmitIsRetriedUnderTheOtherFieldNameAndTheNameIsRemembered() async throws {
        let wire = Wire { _, position in
            position == 1 ? .init(status: 400, json: ["title": "Bad Request", "errors": ["input.model": ["Required"]]]) : .init(json: jobJSON())
        }
        let client = GenerationClient(key: "k", transport: wire.transport)
        var acceptedBefore = await client.acceptedModelField
        XCTAssertEqual(acceptedBefore, "model")
        let job = try await client.submit(prompt: "x", settings: settings())
        XCTAssertEqual(job.id, "wf_1")
        XCTAssertEqual(wire.requests.count, 2)
        let first = try input(of: wire.requests[0]), second = try input(of: wire.requests[1])
        XCTAssertNotNil(first["model"]); XCTAssertNil(first["checkpointModel"])
        XCTAssertNotNil(second["checkpointModel"]); XCTAssertNil(second["model"])
        let accepted = await client.acceptedModelField
        XCTAssertEqual(accepted, "checkpointModel")

        // The accepted name is used from then on, without another failed attempt.
        _ = try await client.submit(prompt: "x", settings: settings())
        XCTAssertEqual(wire.requests.count, 3)
        XCTAssertNotNil(try input(of: wire.requests[2])["checkpointModel"])
        acceptedBefore = await client.acceptedModelField
        XCTAssertEqual(acceptedBefore, "checkpointModel")
    }

    func testTheFallbackAlsoWorksForEstimatesAndFromTheOtherStartingName() async throws {
        let wire = Wire { _, position in
            position == 1 ? .init(status: 422, json: ["detail": "Unknown field"]) : .init(json: ["cost": ["total": 3]])
        }
        let client = GenerationClient(key: "k", modelField: "checkpointModel", transport: wire.transport)
        let cost = try await client.estimate(prompt: "x", settings: settings())
        XCTAssertEqual(cost, 3)
        XCTAssertNotNil(try input(of: wire.requests[0])["checkpointModel"])
        XCTAssertNotNil(try input(of: wire.requests[1])["model"])
        let accepted = await client.acceptedModelField
        XCTAssertEqual(accepted, "model")
    }

    func testWhenBothNamesAreRefusedTheFirstErrorIsReported() async {
        let wire = Wire { _, position in
            position == 1 ? .init(status: 400, json: ["errors": ["input.model": ["First problem"]]]) : .init(status: 400, json: ["errors": ["input.checkpointModel": ["Second problem"]]])
        }
        let client = GenerationClient(key: "k", transport: wire.transport)
        await assertThrows(.invalid("input.model: First problem")) { try await client.submit(prompt: "x", settings: self.settings()) }
        XCTAssertEqual(wire.requests.count, 2, "Retried once, not more")
        let accepted = await client.acceptedModelField
        XCTAssertEqual(accepted, "model", "Nothing was accepted, so nothing changes")
    }

    func testARefusedAnimaRequestIsNotRetriedUnderAnotherFieldName() async throws {
        let wire = Wire { _, _ in .init(status: 400, json: ["errors": ["input.steps": ["Out of range"]]]) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        await assertThrows(.invalid("input.steps: Out of range")) { try await client.submit(prompt: "x", settings: self.animaSettings()) }
        XCTAssertEqual(wire.requests.count, 1, "Anima has no checkpoint field to rename")
        await assertThrows(.invalid("input.steps: Out of range")) { try await client.estimate(prompt: "x", settings: self.animaSettings()) }
        XCTAssertEqual(wire.requests.count, 2)
        let accepted = await client.acceptedModelField
        XCTAssertEqual(accepted, "model")
    }

    func testARefusedSDXLRequestIsStillRetriedOnce() async {
        let wire = Wire { _, _ in .init(status: 400, json: ["detail": "No"]) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        await assertThrows(.invalid("No")) { try await client.submit(prompt: "x", settings: self.settings()) }
        XCTAssertEqual(wire.requests.count, 2)
    }

    func testOtherRefusalsAreNotRetried() async {
        let unauthorized = Wire { _, _ in .init(status: 401, json: ["title": "Unauthorized"]) }
        await assertThrows(.invalidKey) { try await GenerationClient(key: "k", transport: unauthorized.transport).submit(prompt: "x", settings: self.settings()) }
        XCTAssertEqual(unauthorized.requests.count, 1)
        let poor = Wire { _, _ in .init(status: 400, json: ["detail": "Not enough Buzz"]) }
        await assertThrows(.payment) { try await GenerationClient(key: "k", transport: poor.transport).submit(prompt: "x", settings: self.settings()) }
        XCTAssertEqual(poor.requests.count, 1)
    }

    func testAModelProblemFoundBeforeSendingNeverReachesTheService() async {
        let wire = Wire { _, _ in .init(json: jobJSON()) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        await assertThrows(.noModel) { try await client.submit(prompt: "x", settings: self.settings(air: nil)) }
        await assertThrows(.unsupportedModel) { try await client.estimate(prompt: "x", settings: self.settings(air: "urn:air:flux1:checkpoint:civitai:1@2")) }
        XCTAssertTrue(wire.requests.isEmpty)
        await assertThrows(.unsupportedModel) { try await client.submit(prompt: "x", settings: self.settings(air: "urn:air:flux1:checkpoint:civitai:1@2")) }
        XCTAssertTrue(wire.requests.isEmpty)
    }

    // MARK: Error mapping

    func testErrorMappingByStatus() {
        XCTAssertEqual(GenerationClient.error(status: 401, body: nil), .invalidKey)
        XCTAssertEqual(GenerationClient.error(status: 402, body: nil), .payment)
        XCTAssertEqual(GenerationClient.error(status: 403, body: ["detail": "Account is muted"]), .forbidden("Account is muted"))
        XCTAssertEqual(GenerationClient.error(status: 403, body: nil), .forbidden(""))
        XCTAssertEqual(GenerationClient.error(status: 404, body: nil), .notFound)
        XCTAssertEqual(GenerationClient.error(status: 500, body: ["detail": "Boom"]), .failed("Boom"))
        XCTAssertEqual(GenerationClient.error(status: 503, body: nil), .failed(""))
    }

    func testRateLimitCarriesTheRetryAfterSeconds() {
        XCTAssertEqual(GenerationClient.error(status: 429, body: nil, retryAfter: "12"), .busy(12))
        XCTAssertEqual(GenerationClient.error(status: 429, body: nil, retryAfter: nil), .busy(nil))
        XCTAssertEqual(GenerationClient.error(status: 429, body: nil, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT"), .busy(nil))
    }

    func testARateLimitedRequestReportsRetryAfterFromTheHeader() async {
        let wire = Wire { _, _ in .init(status: 429, json: ["title": "Too Many Requests"], headers: ["Retry-After": "7"]) }
        await assertThrows(.busy(7)) { try await GenerationClient(key: "k", transport: wire.transport).account() }
    }

    func testAValidationRefusalListsTheFieldsThatFailed() {
        let body: [String: Any] = ["title": "One or more validation errors occurred.", "errors": ["input.steps": ["Too many", "Must be 8 to 50"], "input.width": ["Bad"]]]
        XCTAssertEqual(GenerationClient.error(status: 400, body: body), .invalid("input.steps: Too many Must be 8 to 50\ninput.width: Bad"))
        XCTAssertEqual(GenerationClient.error(status: 422, body: ["detail": "Bad prompt", "errors": ["prompt": ["Empty"]]]), .invalid("Bad prompt\nprompt: Empty"))
        XCTAssertEqual(GenerationClient.error(status: 400, body: ["title": "Bad Request"]), .invalid("Bad Request"))
        XCTAssertEqual(GenerationClient.error(status: 400, body: nil), .invalid(""))
    }

    func testARefusalAboutBuzzMeansPayment() {
        XCTAssertEqual(GenerationClient.error(status: 400, body: ["detail": "You do not have enough Buzz for this."]), .payment)
        XCTAssertEqual(GenerationClient.error(status: 403, body: ["message": "Insufficient funds"]), .payment)
        XCTAssertEqual(GenerationClient.error(status: 422, body: ["detail": "Low balance"]), .payment)
    }

    func testEveryErrorHasAMessage() {
        let errors: [GenerationError] = [.noKey, .invalidKey, .forbidden(""), .invalid(""), .payment, .busy(3), .blocked(""), .failed(""), .unsupportedModel, .noModel, .notFound, .unreadable]
        for error in errors { XCTAssertFalse(error.message.isEmpty, "\(error)") }
        XCTAssertEqual(GenerationError.invalid("Because").message, "Because")
        XCTAssertTrue(GenerationError.blocked("why").message.hasSuffix("\nwhy"))
        XCTAssertFalse(GenerationError.blocked("").message.hasSuffix("\n"))
    }

    // MARK: Models

    func testVersionReadsTheIdentifierNameAndBase() async throws {
        let wire = Wire { _, _ in .init(json: ["id": 2514310, "name": "v1.0", "baseModel": "Illustrious", "air": testCheckpoint, "model": ["name": "Fixture"]]) }
        let model = try await GenerationClient(key: "k", transport: wire.transport).version(2514310)
        XCTAssertEqual(model.air, testCheckpoint)
        XCTAssertEqual(model.name, "Fixture · v1.0")
        XCTAssertEqual(model.base, "Illustrious")
        XCTAssertEqual(model.versionID, 2514310)
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://civitai.com/api/v1/model-versions/2514310")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testVersionWorksWithoutAKeyAndSendsNoAuthorization() async throws {
        let wire = Wire { _, _ in .init(json: ["name": "v2", "air": "civitai:5@6"]) }
        let model = try await GenerationClient(key: "", transport: wire.transport).version(6)
        XCTAssertEqual(model.name, "v2", "Without a model name the version name stands alone")
        XCTAssertNil(try XCTUnwrap(wire.requests.first).value(forHTTPHeaderField: "Authorization"))
    }

    func testVersionWithoutAReadableIdentifierIsNotFound() async {
        let missing = Wire { _, _ in .init(json: ["name": "v1"]) }
        await assertThrows(.notFound) { try await GenerationClient(key: "k", transport: missing.transport).version(1) }
        let garbage = Wire { _, _ in .init(json: ["name": "v1", "air": "nonsense"]) }
        await assertThrows(.notFound) { try await GenerationClient(key: "k", transport: garbage.transport).version(1) }
        let gone = Wire { _, _ in .init(status: 404, json: ["title": "Not found"]) }
        await assertThrows(.notFound) { try await GenerationClient(key: "k", transport: gone.transport).version(1) }
    }

    func testSearchSendsTheQueryItemsAndReadsTheResults() async throws {
        let wire = Wire { _, _ in .init(json: ["items": [
            ["name": "Alpha", "modelVersions": [["id": 11, "name": "v1", "baseModel": "Pony", "supportsGeneration": true]]],
            ["name": "Beta", "modelVersions": [["id": 20, "name": "old", "supportsGeneration": false], ["id": 21, "name": "new", "baseModel": "SDXL 1.0"]]],
            ["name": "Gamma", "modelVersions": [["id": 30, "name": "x", "supportsGeneration": false]]],
            ["name": "Delta", "modelVersions": []],
            ["modelVersions": [["id": 40, "name": "nameless"]]],
        ]]) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        let found = try await client.search("  anime ", kind: .checkpoint, mature: false)
        XCTAssertEqual(found.map(\.name), ["Alpha · v1", "Beta · new"])
        XCTAssertEqual(found.map(\.versionID), [11, 21])
        XCTAssertEqual(found.map(\.base), ["Pony", "SDXL 1.0"])
        XCTAssertTrue(found.allSatisfy { $0.air.isEmpty }, "Each result still needs a lookup for its identifier")
        let request = try XCTUnwrap(wire.requests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/models")
        let query = queryItems(request)
        XCTAssertEqual(query["query"], "anime")
        XCTAssertEqual(query["types"], "Checkpoint")
        XCTAssertEqual(query["supportsGeneration"], "true")
        XCTAssertEqual(query["nsfw"], "false")
        XCTAssertEqual(query["limit"], "30")
        XCTAssertNil(query["sort"])
    }

    func testSearchForLorasWithMatureAllowedAndNoTextSortsByDownloads() async throws {
        let wire = Wire { _, _ in .init(json: ["items": [Any]()]) }
        let found = try await GenerationClient(key: "", transport: wire.transport).search("  ", kind: .lora, mature: true)
        XCTAssertTrue(found.isEmpty)
        let request = try XCTUnwrap(wire.requests.first)
        let query = queryItems(request)
        XCTAssertEqual(query["types"], "LORA")
        XCTAssertEqual(query["nsfw"], "true")
        XCTAssertEqual(query["supportsGeneration"], "true")
        XCTAssertEqual(query["sort"], "Most Downloaded")
        XCTAssertNil(query["query"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "Searching needs no key")
    }

    func testSearchWithoutItemsIsUnreadable() async {
        let wire = Wire { _, _ in .init(json: ["unexpected": 1]) }
        await assertThrows(.unreadable) { try await GenerationClient(key: "k", transport: wire.transport).search("x", kind: .checkpoint, mature: false) }
    }

    // MARK: Job parsing

    func testJobParsingReadsIdStatusCostImagesAndReasons() throws {
        let object: [String: Any] = [
            "id": "wf_abc", "status": "succeeded", "cost": ["total": 8.5],
            "steps": [[
                "output": ["images": [
                    ["id": "i1", "url": "https://pictures.test/1.png", "width": 832, "height": 1216, "available": true],
                    ["id": "i2", "available": false, "blockedReason": "nsfw"],
                    ["id": "i3", "url": "https://pictures.test/3.png"],
                    ["noId": true],
                    ["id": "i4"],
                ]],
                "jobs": [["reason": "completed", "blockedReason": "first"], ["reason": "later", "blockedReason": "second"]],
            ]],
        ]
        let job = try GenerationClient.job(object)
        XCTAssertEqual(job.id, "wf_abc")
        XCTAssertEqual(job.status, "succeeded")
        XCTAssertEqual(job.cost, 8.5)
        XCTAssertEqual(job.images.map(\.id), ["i1", "i2", "i3", "i4"], "An entry without an id is skipped")
        XCTAssertEqual(job.images[0].url, URL(string: "https://pictures.test/1.png"))
        XCTAssertEqual(job.images[0].width, 832)
        XCTAssertEqual(job.images[0].height, 1216)
        XCTAssertTrue(job.images[0].available)
        XCTAssertFalse(job.images[1].available)
        XCTAssertNil(job.images[1].url)
        XCTAssertEqual(job.images[1].blockedReason, "nsfw")
        XCTAssertTrue(job.images[2].available, "A picture with an address and no flag is available")
        XCTAssertFalse(job.images[3].available, "No address and no flag is not")
        XCTAssertEqual(job.reason, "completed", "The first reason wins")
        XCTAssertEqual(job.blockedReason, "first")
    }

    func testJobParsingDefaultsAndRejects() throws {
        let bare = try GenerationClient.job(["id": "w"])
        XCTAssertEqual(bare.status, "unassigned")
        XCTAssertNil(bare.cost)
        XCTAssertTrue(bare.images.isEmpty)
        XCTAssertEqual(try GenerationClient.job(["id": "w", "cost": 5]).cost, 5, "A plain number is a cost too")
        let estimate = try GenerationClient.job(["cost": ["total": 4]])
        XCTAssertEqual(estimate.id, "", "A dry run has a cost and no id")
        XCTAssertEqual(estimate.cost, 4)
        XCTAssertThrowsError(try GenerationClient.job(["status": "succeeded"])) { XCTAssertEqual($0 as? GenerationError, .unreadable) }
        XCTAssertThrowsError(try GenerationClient.job([1, 2, 3])) { XCTAssertEqual($0 as? GenerationError, .unreadable) }
        XCTAssertThrowsError(try GenerationClient.job("text")) { XCTAssertEqual($0 as? GenerationError, .unreadable) }
    }

    func testJobStatusHelpers() {
        for status in ["succeeded", "failed", "expired", "canceled"] {
            XCTAssertTrue(GenerationJob(id: "w", status: status).isFinished, status)
            XCTAssertFalse(GenerationJob(id: "w", status: status).isQueued, status)
        }
        for status in ["unassigned", "preparing", "scheduled"] {
            XCTAssertTrue(GenerationJob(id: "w", status: status).isQueued, status)
            XCTAssertFalse(GenerationJob(id: "w", status: status).isFinished, status)
        }
        let processing = GenerationJob(id: "w", status: "processing")
        XCTAssertFalse(processing.isFinished)
        XCTAssertFalse(processing.isQueued)
    }

    func testFailureOfAFinishedJob() throws {
        func job(_ status: String, reason: String? = nil, blocked: String? = nil, images: [GenerationImage] = []) -> GenerationJob {
            var job = GenerationJob(id: "w", status: status)
            job.reason = reason; job.blockedReason = blocked; job.images = images
            return job
        }
        let shown = GenerationImage(id: "a", url: URL(string: "https://pictures.test/a.png"), width: 1, height: 1, available: true)
        let withheld = GenerationImage(id: "b", url: nil, width: nil, height: nil, available: false)
        XCTAssertNil(GenerationClient.failure(of: job("succeeded", images: [shown])))
        XCTAssertNil(GenerationClient.failure(of: job("succeeded", images: [withheld, shown])), "One picture to show is enough")

        XCTAssertEqual(GenerationClient.failure(of: job("failed", reason: "blocked", blocked: "minor")), .blocked("minor"))
        XCTAssertEqual(GenerationClient.failure(of: job("failed", reason: "blocked")), .blocked(""))
        XCTAssertEqual(GenerationClient.failure(of: job("succeeded", blocked: "text")), .blocked("text"), "No pictures and a block reason is a block")

        let hidden = try XCTUnwrap(detail(GenerationClient.failure(of: job("succeeded", images: [withheld]))))
        XCTAssertFalse(hidden.isEmpty, "A withheld result explains itself")
        XCTAssertEqual(GenerationClient.failure(of: job("succeeded")), .failed(""))

        let canceled = try XCTUnwrap(detail(GenerationClient.failure(of: job("canceled"))))
        let expired = try XCTUnwrap(detail(GenerationClient.failure(of: job("expired"))))
        let none = try XCTUnwrap(detail(GenerationClient.failure(of: job("failed", reason: "no_provider_available"))))
        XCTAssertFalse(canceled.isEmpty); XCTAssertFalse(expired.isEmpty); XCTAssertFalse(none.isEmpty)
        XCTAssertEqual(Set([hidden, canceled, expired, none]).count, 4, "Each cause has its own words")
        XCTAssertEqual(GenerationClient.failure(of: job("failed")), .failed(""))
    }

    // MARK: Finish

    func testFinishPollsUntilATerminalStatusAndReportsProgress() async throws {
        let wire = Wire { _, position in
            .init(json: jobJSON(id: "wf_1", status: position == 1 ? "scheduled" : position == 2 ? "processing" : "succeeded"))
        }
        let client = GenerationClient(key: "k", transport: wire.transport)
        let seen = Box<String>()
        let start = GenerationJob(id: "wf_1", status: "unassigned")
        let done = try await client.finish(start) { seen.add($0.status) }
        XCTAssertEqual(done.status, "succeeded")
        XCTAssertEqual(done.images.count, 1)
        XCTAssertEqual(wire.requests.count, 3)
        XCTAssertEqual(seen.values, ["unassigned", "scheduled", "processing"], "Progress is reported for each unfinished state, not the last")
        XCTAssertTrue(wire.requests.allSatisfy { $0.url?.path == "/v2/consumer/workflows/wf_1" })
    }

    func testFinishReturnsAFinishedJobWithoutAskingAgain() async throws {
        let wire = Wire { _, _ in .init(json: jobJSON()) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        let progress = Box<String>()
        let done = try await client.finish(GenerationJob(id: "wf_1", status: "failed")) { progress.add($0.status) }
        XCTAssertEqual(done.status, "failed")
        XCTAssertTrue(wire.requests.isEmpty)
        XCTAssertTrue(progress.values.isEmpty)
    }

    func testFinishGivesUpAfterItsTimeLimit() async {
        let wire = Wire { _, _ in .init(json: jobJSON(status: "processing")) }
        let client = GenerationClient(key: "k", transport: wire.transport)
        do {
            _ = try await client.finish(GenerationJob(id: "wf_1", status: "processing"), limit: 0)
            XCTFail("Expected a timeout")
        } catch {
            guard case .failed(let text)? = error as? GenerationError else { return XCTFail("\(error)") }
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertTrue(wire.requests.isEmpty)
    }

    // MARK: Presets

    private func preset(_ name: String) throws -> GenerationPreset {
        try XCTUnwrap(GenerationPreset.all.first { $0.name == name }, name)
    }

    func testAPresetPutsFrontTagsFirstAndBackTagsLast() throws {
        let noob = try preset("NoobAI-XL")
        XCTAssertEqual(noob.applied(to: "1girl, smile"), "masterpiece, best quality, newest, absurdres, highres, safe, 1girl, smile")
        let animagine = try preset("Animagine XL 4.0")
        XCTAssertEqual(animagine.applied(to: "1girl, smile"), "1girl, smile, masterpiece, high score, great score, absurdres")
        XCTAssertEqual(try preset("Pony Diffusion V6 XL").applied(to: "1girl"), "score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up, 1girl")
    }

    func testApplyingAPresetTwiceDoesNotDuplicateItsTags() throws {
        for preset in GenerationPreset.all {
            let once = preset.applied(to: "1girl, smile")
            XCTAssertEqual(preset.applied(to: once), once, preset.name)
        }
    }

    func testSwitchingPresetsRemovesThePreviousPresetsTags() throws {
        let noob = try preset("NoobAI-XL"), animagine = try preset("Animagine XL 4.0"), pony = try preset("Pony Diffusion V6 XL")
        let fromNoob = noob.applied(to: "1girl, smile")
        XCTAssertEqual(animagine.applied(to: fromNoob), "1girl, smile, masterpiece, high score, great score, absurdres")
        let fromAnimagine = animagine.applied(to: "1girl, smile")
        XCTAssertEqual(pony.applied(to: fromAnimagine), "score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up, 1girl, smile")
        XCTAssertEqual(noob.applied(to: pony.applied(to: "1girl")), noob.applied(to: "1girl"))
    }

    func testAPresetTidiesTheTagsAndHandlesAnEmptyPrompt() throws {
        let illustrious = try preset("Illustrious XL")
        XCTAssertEqual(illustrious.applied(to: ""), "masterpiece, best quality")
        XCTAssertEqual(illustrious.applied(to: " 1girl ,, smile , "), "masterpiece, best quality, 1girl, smile")
    }

    func testPresetsStartWithAnima() throws {
        let first = try XCTUnwrap(GenerationPreset.all.first)
        XCTAssertEqual(first.name, "Anima")
        XCTAssertEqual(first.front, "masterpiece, best quality")
        XCTAssertEqual(first.steps, 30)
        XCTAssertEqual(first.guidance, 4)
        XCTAssertEqual(first.applied(to: "1girl"), "masterpiece, best quality, 1girl")
    }

    func testEveryPresetHasUsableSettings() {
        XCTAssertFalse(GenerationPreset.all.isEmpty)
        XCTAssertEqual(Set(GenerationPreset.all.map(\.id)).count, GenerationPreset.all.count)
        for preset in GenerationPreset.all {
            XCTAssertTrue(GenerationSettings.stepRange.contains(preset.steps), preset.name)
            XCTAssertGreaterThan(preset.guidance, 0, preset.name)
        }
    }

    // MARK: Store: settings and key

    func testSettingsSurviveANewStoreOnTheSameSuite() {
        let defaults = makeDefaults()
        let first = makeStore(defaults: defaults)
        var changed = GenerationSettings()
        changed.width = 1024; changed.height = 1024; changed.steps = 30; changed.guidance = 7
        changed.model = GenerationModel(air: testCheckpoint, name: "Model", base: "Illustrious", versionID: 2514310)
        changed.loras = [GenerationLora(model: GenerationModel(air: "urn:air:sdxl:lora:civitai:1@2", name: "L"), strength: 0.4)]
        changed.seed = 42; changed.quantity = 3; changed.mature = true; changed.negative = "bad"
        first.settings = changed
        let second = makeStore(defaults: defaults)
        XCTAssertEqual(second.settings, changed)
    }

    func testASavedSettingWithoutAModelGetsTheRecommendedOneAndKeepsTheRest() {
        let defaults = makeDefaults()
        var saved = GenerationSettings()
        saved.width = 1024; saved.height = 1024; saved.negative = "bad"; saved.seed = 5; saved.quantity = 2; saved.mature = true
        saved.model = nil
        makeStore(defaults: defaults).settings = saved
        let loaded = makeStore(defaults: defaults).settings
        XCTAssertEqual(loaded.model, GenerationModel.recommended)
        XCTAssertEqual(loaded.width, 1024)
        XCTAssertEqual(loaded.height, 1024)
        XCTAssertEqual(loaded.negative, "bad")
        XCTAssertEqual(loaded.seed, 5)
        XCTAssertEqual(loaded.quantity, 2)
        XCTAssertTrue(loaded.mature)
        XCTAssertEqual(loaded.steps, 30, "Choosing the Anima model applies its values")
        XCTAssertEqual(loaded.guidance, 4)
        XCTAssertEqual(loaded.sampler, "euler")
        XCTAssertEqual(loaded.schedule, "simple")
    }

    func testAFreshStoreStartsWithDefaultSettingsAndNoPictures() {
        let store = makeStore()
        XCTAssertEqual(store.settings, GenerationSettings.starting)
        XCTAssertEqual(store.settings.model, GenerationModel.recommended)
        XCTAssertTrue(store.pictures.isEmpty)
        XCTAssertTrue(store.recentModels.isEmpty)
        XCTAssertFalse(store.hasKey)
    }

    func testTheKeyIsNeverWrittenToPreferencesOrThePictureFolder() throws {
        let defaults = makeDefaults()
        let folder = makeFolder()
        let first = "FIRST-SECRET-KEY-1111", second = "SECOND-SECRET-KEY-2222"
        let store = makeStore(defaults: defaults, folder: folder, key: first)
        XCTAssertTrue(store.save(key: second))
        var changed = settings()
        changed.seed = 7
        store.settings = changed
        store.remember(try XCTUnwrap(changed.model))
        _ = try store.add(testPNG, prompt: "x", settings: changed)
        _ = store.client(); _ = store.client(key: first)

        for secret in [first, second] {
            let preferences = String(describing: defaults.dictionaryRepresentation())
            XCTAssertFalse(preferences.contains(secret), "Preferences hold no key")
            for value in defaults.dictionaryRepresentation().values {
                if let data = value as? Data { XCTAssertNil(data.range(of: Data(secret.utf8)), "No stored data holds the key") }
            }
            let files = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)).allObjects.compactMap { $0 as? URL }
            XCTAssertFalse(files.isEmpty)
            for file in files {
                XCTAssertFalse(file.lastPathComponent.contains(secret))
                XCTAssertNil(try Data(contentsOf: file).range(of: Data(secret.utf8)), "\(file.lastPathComponent) holds no key")
            }
        }
    }

    func testSaveKeyTogglesHasKeyAndPassesTheTrimmedKeyToTheSaver() {
        let saved = Box<String>()
        let store = makeStore(saveKey: { saved.add($0); return true })
        XCTAssertFalse(store.hasKey)
        XCTAssertTrue(store.save(key: "  abc \n"))
        XCTAssertTrue(store.hasKey)
        XCTAssertTrue(store.save(key: ""))
        XCTAssertFalse(store.hasKey)
        XCTAssertTrue(store.save(key: "   "))
        XCTAssertFalse(store.hasKey)
        XCTAssertEqual(saved.values, ["abc", "", ""])
    }

    func testSaveKeyReturnsFalseAndChangesNothingWhenTheSaverFails() {
        let store = makeStore(key: "old", saveKey: { _ in false })
        XCTAssertTrue(store.hasKey)
        XCTAssertFalse(store.save(key: "new"))
        XCTAssertTrue(store.hasKey)
        XCTAssertFalse(store.save(key: ""))
        XCTAssertTrue(store.hasKey, "A key that could not be removed is still there")
        let empty = makeStore(key: "", saveKey: { _ in false })
        XCTAssertFalse(empty.save(key: "new"))
        XCTAssertFalse(empty.hasKey)
    }

    func testTheSavedKeyIsTheOneClientsUse() async throws {
        let wire = Wire { _, _ in .init(json: ["username": "u", "status": "active"]) }
        let store = makeStore(key: "old-key", transport: wire.transport)
        _ = try await store.client().account()
        XCTAssertTrue(store.save(key: "new-key"))
        _ = try await store.client().account()
        _ = try await store.client(key: "typed-key").account()
        XCTAssertEqual(wire.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer old-key", "Bearer new-key", "Bearer typed-key"])
    }

    func testClientStartsWithTheRememberedCheckpointField() async throws {
        let defaults = makeDefaults()
        let wire = Wire { _, _ in .init(json: jobJSON()) }
        let store = makeStore(defaults: defaults, key: "k", transport: wire.transport)
        store.remember(modelField: "checkpointModel")
        _ = try await store.client().submit(prompt: "x", settings: settings())
        XCTAssertNotNil(try input(of: wire.requests[0])["checkpointModel"])
        let other = makeStore(defaults: defaults, key: "k", transport: wire.transport)
        _ = try await other.client().submit(prompt: "x", settings: settings())
        XCTAssertNotNil(try input(of: wire.requests[1])["checkpointModel"], "Remembered across stores")
    }

    // MARK: Store: recent models

    func testRecentModelsAreNewestFirstWithoutDuplicatesAndCappedAtTwelve() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        let models = (1...14).map { GenerationModel(air: "urn:air:sdxl:checkpoint:civitai:\($0)@\($0)", name: "Model \($0)") }
        for model in models { store.remember(model) }
        XCTAssertEqual(store.recentModels.count, 12)
        XCTAssertEqual(store.recentModels.first?.name, "Model 14")
        XCTAssertEqual(store.recentModels.last?.name, "Model 3")

        store.remember(models[5])
        XCTAssertEqual(store.recentModels.count, 12)
        XCTAssertEqual(store.recentModels.first?.name, "Model 6", "Seeing a model again moves it to the front")
        XCTAssertEqual(store.recentModels.filter { $0.air == models[5].air }.count, 1)
        XCTAssertEqual(store.recentModels[1].name, "Model 14")

        var renamed = models[5]; renamed.name = "Renamed"
        store.remember(renamed)
        XCTAssertEqual(store.recentModels.first?.name, "Renamed")
        XCTAssertEqual(store.recentModels.count, 12)

        XCTAssertEqual(makeStore(defaults: defaults).recentModels, store.recentModels, "Kept across launches")
    }

    // MARK: Store: pictures

    func testAddWritesAFileWhoseExtensionMatchesTheData() throws {
        let store = makeStore()
        let png = try store.add(testPNG, prompt: "p", settings: settings())
        let jpg = try store.add(testJPEG, prompt: "q", settings: settings())
        let webp = try store.add(Data("RIFF....WEBP".utf8), prompt: "r", settings: settings())
        XCTAssertEqual(URL(fileURLWithPath: png.file).pathExtension, "png")
        XCTAssertEqual(URL(fileURLWithPath: jpg.file).pathExtension, "jpg")
        XCTAssertEqual(URL(fileURLWithPath: webp.file).pathExtension, "webp")
        XCTAssertEqual(try Data(contentsOf: store.url(png)), testPNG)
        XCTAssertEqual(try Data(contentsOf: store.url(jpg)), testJPEG)
        XCTAssertEqual(store.url(png).deletingLastPathComponent().standardizedFileURL, store.folder.standardizedFileURL)
        XCTAssertEqual(store.pictures.map(\.prompt), ["r", "q", "p"], "Newest first")
    }

    func testAddKeepsWhatThePictureWasMadeFrom() throws {
        var made = settings()
        made.negative = "ugly"; made.steps = 33; made.guidance = 6.5; made.seed = 99; made.width = 896; made.height = 1152
        let store = makeStore()
        let picture = try store.add(testPNG, prompt: "1girl", settings: made)
        XCTAssertEqual(picture.prompt, "1girl")
        XCTAssertEqual(picture.negative, "ugly")
        XCTAssertEqual(picture.model, testCheckpoint)
        XCTAssertEqual(picture.modelName, "Model")
        XCTAssertEqual(picture.steps, 33)
        XCTAssertEqual(picture.guidance, 6.5)
        XCTAssertEqual(picture.seed, 99)
        XCTAssertEqual(picture.width, 896)
        XCTAssertEqual(picture.height, 1152)
        let sized = try store.add(testPNG, prompt: "x", settings: made, size: (width: 640, height: 480))
        XCTAssertEqual(sized.width, 640)
        XCTAssertEqual(sized.height, 480)
    }

    func testThePictureIndexSurvivesANewStore() throws {
        let defaults = makeDefaults(), folder = makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        let one = try store.add(testPNG, prompt: "one", settings: settings())
        let two = try store.add(testJPEG, prompt: "two", settings: settings())
        let again = makeStore(defaults: defaults, folder: folder)
        XCTAssertEqual(again.pictures.map(\.id), [two.id, one.id])
        XCTAssertEqual(again.pictures.map(\.prompt), ["two", "one"])
        XCTAssertEqual(try Data(contentsOf: again.url(two)), testJPEG)
    }

    func testDeleteRemovesTheFileAndTheEntry() throws {
        let defaults = makeDefaults(), folder = makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        let keep = try store.add(testPNG, prompt: "keep", settings: settings())
        let drop = try store.add(testPNG, prompt: "drop", settings: settings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(drop).path))
        store.delete(drop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(drop).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(keep).path))
        XCTAssertEqual(store.pictures.map(\.id), [keep.id])
        XCTAssertEqual(makeStore(defaults: defaults, folder: folder).pictures.map(\.id), [keep.id], "The deletion is saved")
        store.delete(drop)
        XCTAssertEqual(store.pictures.count, 1, "Deleting twice is harmless")
    }

    func testPicturesWhoseFileIsMissingAreDroppedOnLoad() throws {
        let defaults = makeDefaults(), folder = makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        let lost = try store.add(testPNG, prompt: "lost", settings: settings())
        let kept = try store.add(testPNG, prompt: "kept", settings: settings())
        try FileManager.default.removeItem(at: store.url(lost))
        let again = makeStore(defaults: defaults, folder: folder)
        XCTAssertEqual(again.pictures.map(\.id), [kept.id])
    }

    func testACorruptIndexLeavesAnEmptyLibraryInsteadOfFailing() throws {
        let folder = makeFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("index.json"))
        XCTAssertTrue(makeStore(folder: folder).pictures.isEmpty)
    }

    // MARK: Run

    private func wait(for run: GenerationRun, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while run.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func fakeService(submitted: @escaping @Sendable (Int) -> Wire.Reply) -> Wire {
        Wire { request, position in
            if request.url?.host == "pictures.test" { return .init(data: testPNG) }
            if request.httpMethod == "POST" { return submitted(position) }
            return .init(json: jobJSON(status: "succeeded", cost: 10))
        }
    }

    func testARunMakesOnePictureAndRemembersTheCost() async throws {
        let wire = fakeService { _ in .init(json: jobJSON(status: "succeeded", cost: 10)) }
        let store = makeStore(key: "k", transport: wire.transport)
        let run = GenerationRun()
        XCTAssertFalse(run.isRunning)
        run.start(prompt: "1girl", settings: settings(), store: store)
        XCTAssertTrue(run.isRunning)
        await wait(for: run)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.phase, .idle)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.made.count, 1)
        XCTAssertEqual(run.lastCost, 10)
        XCTAssertEqual(store.pictures.count, 1)
        let picture = try XCTUnwrap(run.made.first)
        XCTAssertEqual(picture.prompt, "1girl")
        XCTAssertEqual(picture.width, 832)
        XCTAssertEqual(picture.height, 1216)
        XCTAssertEqual(try Data(contentsOf: store.url(picture)), testPNG)
        let download = try XCTUnwrap(wire.requests.first { $0.url?.host == "pictures.test" })
        XCTAssertNil(download.value(forHTTPHeaderField: "Authorization"))
    }

    func testARunThatStartsQueuedWaitsForTheJobToFinish() async throws {
        let wire = fakeService { _ in .init(json: jobJSON(status: "scheduled", cost: 6)) }
        let store = makeStore(key: "k", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "x", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.made.count, 1)
        XCTAssertEqual(run.lastCost, 10, "The finished job's cost is the one kept")
        XCTAssertTrue(wire.requests.contains { $0.httpMethod == "GET" && $0.url?.path == "/v2/consumer/workflows/wf_1" })
    }

    func testABlockedJobEndsWithABlockedErrorAndNoPicture() async {
        let blocked = jobJSON(status: "failed", images: [], jobs: [["reason": "blocked", "blockedReason": "Prompt not allowed"]])
        let wire = fakeService { _ in .init(json: blocked) }
        let store = makeStore(key: "k", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "x", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.error, .blocked("Prompt not allowed"))
        XCTAssertTrue(run.made.isEmpty)
        XCTAssertTrue(store.pictures.isEmpty)
    }

    func testARunWithARefusedKeyEndsWithInvalidKey() async {
        let wire = fakeService { _ in .init(status: 401, json: ["title": "Unauthorized"]) }
        let store = makeStore(key: "wrong", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "x", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertFalse(run.isRunning)
        XCTAssertEqual(run.error, .invalidKey)
        XCTAssertTrue(run.made.isEmpty)
    }

    func testARunWithoutAKeyOrModelFailsWithoutSendingAnything() async {
        let wire = fakeService { _ in .init(json: jobJSON()) }
        let keyless = makeStore(key: "", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "x", settings: settings(), store: keyless)
        await wait(for: run)
        XCTAssertEqual(run.error, .noKey)
        let keyed = makeStore(key: "k", transport: wire.transport)
        let second = GenerationRun()
        second.start(prompt: "x", settings: settings(air: nil), store: keyed)
        await wait(for: second)
        XCTAssertEqual(second.error, .noModel)
        XCTAssertTrue(wire.requests.isEmpty)
    }

    func testARunClearsItsPreviousErrorWhenStartedAgain() async {
        let wire = Wire { request, _ in
            if request.url?.host == "pictures.test" { return .init(data: testPNG) }
            return .init(json: jobJSON())
        }
        let store = makeStore(key: "", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "x", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertEqual(run.error, .noKey)
        _ = store.save(key: "k")
        run.start(prompt: "x", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.made.count, 1)
        run.forget(run.made[0])
        XCTAssertTrue(run.made.isEmpty)
    }

    func testARunRemembersTheCheckpointFieldTheServiceAccepted() async {
        let wire = fakeService { position in
            position == 1 ? .init(status: 400, json: ["errors": ["input.model": ["Required"]]]) : .init(json: jobJSON())
        }
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults, key: "k", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "x", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertNil(run.error)
        XCTAssertEqual(run.made.count, 1)
        XCTAssertEqual(defaults.string(forKey: "generation.modelField"), "checkpointModel")
    }

    func testStartWhileRunningIsIgnored() async {
        let wire = fakeService { _ in .init(json: jobJSON()) }
        let store = makeStore(key: "k", transport: wire.transport)
        let run = GenerationRun()
        run.start(prompt: "first", settings: settings(), store: store)
        run.start(prompt: "second", settings: settings(), store: store)
        await wait(for: run)
        XCTAssertEqual(run.made.map(\.prompt), ["first"])
    }
}
