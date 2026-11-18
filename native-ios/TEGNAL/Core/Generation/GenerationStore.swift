import Foundation
import Observation

/// The API key lives only in the keychain: never in preferences, backups, sync, exports or logs.
enum GenerationKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "work.nextline.tegnal.generation", kSecAttrAccount as String: "civitai"]
    static func read() -> String {
        var item = query; item[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    @discardableResult static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Quality tags, things to avoid and settings as a model's own card recommends them.
struct GenerationPreset: Hashable, Identifiable, Sendable {
    let name: String
    /// Written before the prompt.
    var front = ""
    /// Written after the prompt.
    var back = ""
    var negative = ""
    var steps: Int
    var guidance: Double
    var id: String { name }

    static let all: [GenerationPreset] = [
        .init(name: "Anima", front: "masterpiece, best quality", negative: "worst quality, low quality, blurry, bad anatomy, deformed hands", steps: 30, guidance: 4),
        .init(name: "NoobAI-XL", front: "masterpiece, best quality, newest, absurdres, highres, safe",
              negative: "nsfw, worst quality, old, early, low quality, lowres, signature, username, logo, bad hands, mutated hands, mammal, anthro, furry, ambiguous form, feral, semi-anthro", steps: 28, guidance: 5.5),
        .init(name: "Illustrious XL", front: "masterpiece, best quality",
              negative: "worst quality, comic, multiple views, bad quality, low quality, lowres, displeasing, very displeasing, bad anatomy, bad hands, scan artifacts, monochrome, greyscale, signature, twitter username, jpeg artifacts, 2koma, 4koma, guro, extra digits, fewer digits", steps: 28, guidance: 6),
        .init(name: "Animagine XL 4.0", back: "masterpiece, high score, great score, absurdres",
              negative: "lowres, bad anatomy, bad hands, text, error, missing finger, extra digits, fewer digits, cropped, worst quality, low quality, low score, bad score, average score, signature, watermark, username, blurry", steps: 28, guidance: 5),
        .init(name: "Pony Diffusion V6 XL", front: "score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up", steps: 25, guidance: 7),
    ]

    /// The prompt with this preset's quality tags around it, and without any other preset's.
    func applied(to prompt: String) -> String {
        var tags = prompt.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let known = Set(Self.all.flatMap { Self.tags($0.front) + Self.tags($0.back) })
        tags.removeAll { known.contains($0) }
        return (Self.tags(front) + tags + Self.tags(back)).joined(separator: ", ")
    }
    private static func tags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// A picture made here, kept on this device with what it was made from.
struct GeneratedPicture: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var file: String
    var prompt: String
    var negative: String
    var model: String
    var modelName: String
    var width: Int
    var height: Int
    var steps: Int
    var guidance: Double
    var seed: Int64?
    var date = Date()
}

@MainActor @Observable
final class GenerationStore {
    static let shared: GenerationStore = {
        #if DEBUG
        if GenerationUITestSupport.enabled { return GenerationUITestSupport.store() }
        #endif
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Generated", isDirectory: true) ?? FileManager.default.temporaryDirectory.appendingPathComponent("Generated", isDirectory: true)
        return GenerationStore(folder: folder, defaults: ReaderPreferences.booruDefaults, key: GenerationKeychain.read(), saveKey: { GenerationKeychain.save($0) })
    }()
    static let pictureLimit = 200
    private static let settingsKey = "generation.settings", recentKey = "generation.recentModels", fieldKey = "generation.modelField"

    let folder: URL
    private let defaults: UserDefaults
    private let saveKey: (String) -> Bool
    private let transport: GenerationClient.Transport?
    private var key: String
    private(set) var hasKey: Bool
    private(set) var recentModels: [GenerationModel] = []
    private(set) var pictures: [GeneratedPicture] = []
    var settings: GenerationSettings { didSet { if settings != oldValue { store(settings, Self.settingsKey) } } }

    init(folder: URL, defaults: UserDefaults, key: String, saveKey: @escaping (String) -> Bool, transport: GenerationClient.Transport? = nil) {
        self.folder = folder; self.defaults = defaults; self.key = key; self.saveKey = saveKey; self.transport = transport
        hasKey = !key.isEmpty
        settings = Self.load(GenerationSettings.self, Self.settingsKey, defaults) ?? .starting
        // A generator set up before there was a suggested model, and never given one, starts with it too.
        if settings.model == nil { settings.use(.recommended) }
        recentModels = Self.load([GenerationModel].self, Self.recentKey, defaults) ?? []
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: index), let saved = try? JSONDecoder().decode([GeneratedPicture].self, from: data) {
            pictures = saved.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }
        }
    }

    private var index: URL { folder.appendingPathComponent("index.json") }
    private static func load<Value: Decodable>(_ type: Value.Type, _ name: String, _ defaults: UserDefaults) -> Value? {
        defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    private func store<Value: Encodable>(_ value: Value, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: name) }
    }

    func client() -> GenerationClient {
        GenerationClient(key: key, modelField: defaults.string(forKey: Self.fieldKey) ?? GenerationClient.modelFields[0], transport: transport)
    }
    /// A client for a key that has not been saved yet, to check it with.
    func client(key: String) -> GenerationClient { GenerationClient(key: key, transport: transport) }
    func remember(modelField: String) { defaults.set(modelField, forKey: Self.fieldKey) }

    @discardableResult func save(key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard saveKey(trimmed) else { return false }
        self.key = trimmed; hasKey = !trimmed.isEmpty
        return true
    }

    func remember(_ model: GenerationModel) {
        recentModels.removeAll { $0.air == model.air }
        recentModels.insert(model, at: 0)
        recentModels = Array(recentModels.prefix(12))
        store(recentModels, Self.recentKey)
    }

    func url(_ picture: GeneratedPicture) -> URL { folder.appendingPathComponent(picture.file) }

    @discardableResult func add(_ data: Data, prompt: String, settings: GenerationSettings, size: (width: Int, height: Int)? = nil) throws -> GeneratedPicture {
        let type = data.starts(with: [0x89, 0x50]) ? "png" : data.starts(with: [0x52, 0x49]) ? "webp" : "jpg"
        var picture = GeneratedPicture(file: "", prompt: prompt, negative: settings.negative, model: settings.model?.air ?? "", modelName: settings.model?.name ?? "",
                                       width: size?.width ?? settings.width, height: size?.height ?? settings.height, steps: settings.steps, guidance: settings.guidance, seed: settings.seed)
        picture.file = picture.id.uuidString + "." + type
        try data.write(to: url(picture), options: .atomic)
        pictures.insert(picture, at: 0)
        for old in pictures.dropFirst(Self.pictureLimit) { try? FileManager.default.removeItem(at: url(old)) }
        pictures = Array(pictures.prefix(Self.pictureLimit))
        persist()
        return picture
    }

    func delete(_ picture: GeneratedPicture) {
        try? FileManager.default.removeItem(at: url(picture))
        pictures.removeAll { $0.id == picture.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(pictures) { try? data.write(to: index, options: .atomic) }
    }
}

/// One run of the generator: what it is doing now and what it has made.
@MainActor @Observable
final class GenerationRun {
    enum Phase: Equatable { case idle, sending, queued, drawing, saving }
    private(set) var phase = Phase.idle
    private(set) var error: GenerationError?
    private(set) var made: [GeneratedPicture] = []
    private(set) var lastCost: Double?
    private var task: Task<Void, Never>?
    private var jobID: String?
    var isRunning: Bool { phase != .idle }

    func start(prompt: String, settings: GenerationSettings, store: GenerationStore) {
        guard !isRunning else { return }
        error = nil; phase = .sending
        let client = store.client()
        task = Task { [weak self] in
            do {
                var job = try await client.submit(prompt: prompt, settings: settings)
                store.remember(modelField: await client.acceptedModelField)
                self?.jobID = job.id
                self?.phase = job.isQueued ? .queued : .drawing
                job = try await client.finish(job) { current in await MainActor.run { self?.phase = current.isQueued ? .queued : .drawing } }
                self?.lastCost = job.cost
                if let failure = GenerationClient.failure(of: job) { throw failure }
                self?.phase = .saving
                for image in job.images where image.available {
                    guard let url = image.url else { continue }
                    let data = try await client.picture(url)
                    let picture = try store.add(data, prompt: prompt, settings: settings, size: image.width.flatMap { width in image.height.map { (width, $0) } })
                    self?.made.insert(picture, at: 0)
                }
            } catch is CancellationError {
            } catch let failure as GenerationError { self?.error = failure
            } catch let failure as URLError where failure.code == .cancelled {
            } catch { self?.error = .failed(error.localizedDescription) }
            self?.jobID = nil; self?.phase = .idle
        }
    }

    func cancel(store: GenerationStore) {
        task?.cancel()
        if let jobID { let client = store.client(); Task { await client.cancel(jobID) } }
    }
    func forget(_ picture: GeneratedPicture) { made.removeAll { $0.id == picture.id } }
}

#if DEBUG
/// A stand-in for the service, so that UI tests neither need a key nor spend anything.
enum GenerationUITestSupport {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--generation-ui-test") }
    static let model = GenerationModel(air: "urn:air:sdxl:checkpoint:civitai:827184@2514310", name: "Fixture Model · v1", base: "Illustrious", versionID: 2514310)
    /// A one-by-one PNG.
    static let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    @MainActor static func store() -> GenerationStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("generation-ui-test", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let defaults = UserDefaults(suiteName: "generation-ui-test")!
        defaults.removePersistentDomain(forName: "generation-ui-test")
        let keyed = !ProcessInfo.processInfo.arguments.contains("--generation-no-key")
        return GenerationStore(folder: folder, defaults: defaults, key: keyed ? "fixture" : "", saveKey: { _ in true }, transport: transport)
    }
    static let transport: GenerationClient.Transport = { request in
        let url = request.url!, path = url.path
        func answer(_ object: Any, status: Int = 200) -> (Data, HTTPURLResponse) {
            ((try? JSONSerialization.data(withJSONObject: object)) ?? Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if url.host == "fixture.invalid" { return (picture, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        if path.hasSuffix("/me") {
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer wrong" ? answer(["error": "Unauthorized"], status: 401) : answer(["username": "fixture_user", "status": "active"])
        }
        if path.contains("/model-versions/") { return answer(["id": 2514310, "name": "v1", "baseModel": "Illustrious", "air": model.air, "model": ["name": "Fixture Model"]]) }
        if path.hasSuffix("/models") {
            return answer(["items": [["name": "Fixture Model", "modelVersions": [["id": 2514310, "name": "v1", "baseModel": "Illustrious", "supportsGeneration": true]]]]])
        }
        if url.query?.contains("whatif=true") == true { return answer(["cost": ["total": 10]]) }
        try? await Task.sleep(for: .milliseconds(300))
        return answer(["id": "wf_fixture", "status": "succeeded", "cost": ["total": 10],
                       "steps": [["output": ["images": [["id": "fixture.png", "url": "https://fixture.invalid/fixture.png", "available": true, "width": 832, "height": 1216]]]]]])
    }
}
#endif
