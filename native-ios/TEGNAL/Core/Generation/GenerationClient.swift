import Foundation

/// A model or add-on that can be generated with.
struct GenerationModel: Codable, Hashable, Identifiable, Sendable {
    /// The full AIR identifier; empty until a search result has been looked up.
    var air: String
    var name: String
    /// What the model was built on, as its page says ("Illustrious", "Pony", "SDXL 1.0").
    var base: String?
    var versionID: Int?
    var id: String { air.isEmpty ? "version:\(versionID ?? 0)" : air }
}

struct GenerationLora: Codable, Hashable, Identifiable, Sendable {
    var model: GenerationModel
    var strength = 0.8
    var id: String { model.id }
}

/// Everything about a picture except its prompt.
struct GenerationSettings: Codable, Equatable, Sendable {
    var model: GenerationModel?
    var loras: [GenerationLora] = []
    var negative = "worst quality, low quality, lowres, bad anatomy, bad hands, signature, watermark, username, blurry"
    var width = 832
    var height = 1216
    var steps = 25
    var guidance = 5.5
    var sampler = "euler_a"
    var schedule = "discrete"
    /// Nil draws a new seed each time.
    var seed: Int64?
    var quantity = 1
    /// Whether results the service rates as mature may be returned.
    var mature = false

    static let sizes: [(width: Int, height: Int)] = [(832, 1216), (896, 1152), (1024, 1024), (1152, 896), (1216, 832)]
    static let samplers = ["euler_a", "euler", "dpm++2m", "dpm++2s_a", "lcm"]
    static let schedules = ["discrete", "karras", "sgm_uniform"]
    static let stepRange = 8...50
    static let quantityRange = 1...4

    /// The service's own estimate comes from a dry run; this is the published formula, for when there is none yet.
    var roughCost: Int {
        Int((8.0 * Double(width * height) / Double(1024 * 1024) * Double(steps) / 20.0 * Double(quantity)).rounded(.up))
    }
}

struct GenerationImage: Hashable, Identifiable, Sendable {
    let id: String
    var url: URL?
    var width: Int?
    var height: Int?
    /// False while the picture is withheld, for instance for being rated mature when that was not allowed.
    var available = true
    var blockedReason: String?
}

/// A request as the service reports it.
struct GenerationJob: Hashable, Sendable {
    var id: String
    var status: String
    var cost: Double?
    var images: [GenerationImage] = []
    var reason: String?
    var blockedReason: String?
    var isFinished: Bool { ["succeeded", "failed", "expired", "canceled"].contains(status) }
    var isQueued: Bool { ["unassigned", "preparing", "scheduled"].contains(status) }
}

struct GenerationAccount: Hashable, Sendable {
    var name: String
    var status: String
}

enum GenerationError: Error, Equatable {
    /// No API key has been saved.
    case noKey
    /// The key was refused.
    case invalidKey
    /// The key is good but the account may not do this.
    case forbidden(String)
    /// The request was not accepted as written.
    case invalid(String)
    /// Not enough Buzz to pay for the request.
    case payment
    /// Too many requests; the number is how many seconds to wait, when the service says.
    case busy(Int?)
    /// Refused by the service's content moderation. The same prompt must not be sent again.
    case blocked(String)
    case failed(String)
    /// The model is not one this generator can run.
    case unsupportedModel
    case noModel
    case notFound
    case unreadable

    var message: String {
        switch self {
        case .noKey: L10n.text("Add your Civitai API key to generate pictures.")
        case .invalidKey: L10n.text("Civitai did not accept this API key.")
        case .forbidden(let detail): detail.isEmpty ? L10n.text("This account is not allowed to make this request.") : detail
        case .invalid(let detail): detail.isEmpty ? L10n.text("The request was not accepted.") : detail
        case .payment: L10n.text("Not enough Buzz on this account.")
        case .busy: L10n.text("Too many requests. Wait a moment and try again.")
        case .blocked(let detail): L10n.text("Civitai's moderation refused this prompt. Change it before trying again; repeated refusals can get an account muted.") + (detail.isEmpty ? "" : "\n" + detail)
        case .failed(let detail): detail.isEmpty ? L10n.text("The picture could not be generated.") : detail
        case .unsupportedModel: L10n.text("This generator runs Stable Diffusion 1.5 and SDXL-family checkpoints, such as Illustrious, NoobAI, Pony and Animagine.")
        case .noModel: L10n.text("Choose a model first.")
        case .notFound: L10n.text("Nothing was found for this.")
        case .unreadable: L10n.text("The answer could not be read.")
        }
    }
}

/// Talks to Civitai's generation service with the user's own API key. The key travels only in the `Authorization`
/// header of calls to Civitai's two API hosts; pictures are fetched from their signed addresses without it.
actor GenerationClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let site = URL(string: "https://civitai.com/api/v1")!
    static let service = URL(string: "https://orchestration.civitai.com/v2/consumer")!
    /// The two names the service's documents give the checkpoint field; the one that is accepted is remembered.
    static let modelFields = ["model", "checkpointModel"]

    private let key: String
    private let transport: Transport
    private var modelField: String

    init(key: String, modelField: String = GenerationClient.modelFields[0], transport: Transport? = nil) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelField = modelField
        self.transport = transport ?? Self.network
    }
    var acceptedModelField: String { modelField }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 75
        return URLSession(configuration: config)
    }()
    private static let network: Transport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GenerationError.unreadable }
        return (data, http)
    }

    // MARK: Requests

    /// The body of a text-to-image request. `field` names the checkpoint.
    static func body(prompt: String, settings: GenerationSettings, field: String = modelFields[0]) throws -> [String: Any] {
        guard let model = settings.model, let air = GenerationAIR(model.air) else { throw GenerationError.noModel }
        guard let family = air.family, air.kind == .checkpoint || air.type == nil else { throw GenerationError.unsupportedModel }
        var input: [String: Any] = [
            "engine": "sdcpp", "ecosystem": family.rawValue, "operation": "createImage", field: air.text,
            "prompt": prompt, "width": settings.width, "height": settings.height, "steps": settings.steps,
            "cfgScale": settings.guidance, "sampleMethod": settings.sampler, "schedule": settings.schedule, "quantity": settings.quantity,
        ]
        let negative = settings.negative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !negative.isEmpty { input["negativePrompt"] = negative }
        if let seed = settings.seed { input["seed"] = seed }
        let loras = settings.loras.filter { GenerationAIR($0.model.air) != nil }
        if !loras.isEmpty { input["loras"] = Dictionary(loras.map { ($0.model.air, $0.strength) }, uniquingKeysWith: { first, _ in first }) }
        var body: [String: Any] = ["steps": [["$type": "imageGen", "input": input]]]
        // Left unset, the service decides by which Buzz paid; false keeps mature results from being returned.
        if !settings.mature { body["allowMatureContent"] = false }
        return body
    }

    private func request(_ url: URL, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil, authorized: Bool = true) throws -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized {
            guard !key.isEmpty else { throw GenerationError.noKey }
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await transport(request)
        let object = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(response.statusCode) else { throw Self.error(status: response.statusCode, body: object as? [String: Any], retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        guard let object else { throw GenerationError.unreadable }
        return object
    }

    /// What a refusal means. Problem bodies carry a `title`, a `detail` and, for a request that failed validation, `errors` by field.
    static func error(status: Int, body: [String: Any]?, retryAfter: String? = nil) -> GenerationError {
        var lines = [body?["detail"] as? String, body?["message"] as? String].compactMap { $0 }
        if let errors = body?["errors"] as? [String: Any] {
            for (field, value) in errors.sorted(by: { $0.key < $1.key }) {
                lines.append(field + ": " + ((value as? [String])?.joined(separator: " ") ?? "\(value)"))
            }
        }
        if lines.isEmpty, let title = body?["title"] as? String ?? body?["error"] as? String { lines.append(title) }
        let detail = lines.joined(separator: "\n")
        let lowered = detail.lowercased()
        let money = ["buzz", "funds", "payment", "balance"].contains { lowered.contains($0) }
        switch status {
        case 401: return .invalidKey
        case 402: return .payment
        case 403: return money ? .payment : .forbidden(detail)
        case 404: return .notFound
        case 429: return .busy(retryAfter.flatMap(Int.init))
        case 400, 409, 422: return money ? .payment : .invalid(detail)
        default: return .failed(detail)
        }
    }

    // MARK: Account and models

    /// Asks who the key belongs to, which is also how a key is checked.
    func account() async throws -> GenerationAccount {
        guard let object = try await send(request(Self.site.appendingPathComponent("me"))) as? [String: Any] else { throw GenerationError.unreadable }
        return .init(name: object["username"] as? String ?? "", status: object["status"] as? String ?? "")
    }

    /// The model version with this id, with its AIR identifier.
    func version(_ id: Int) async throws -> GenerationModel {
        guard let object = try await send(request(Self.site.appendingPathComponent("model-versions/\(id)"), authorized: !key.isEmpty)) as? [String: Any],
              let air = object["air"] as? String, GenerationAIR(air) != nil else { throw GenerationError.notFound }
        let model = (object["model"] as? [String: Any])?["name"] as? String
        let name = [model, object["name"] as? String].compactMap { $0 }.joined(separator: " · ")
        return .init(air: air, name: name.isEmpty ? air : name, base: object["baseModel"] as? String, versionID: id)
    }

    /// Models that can be generated with on the service, by name. Each result still needs `version(_:)` for its identifier.
    func search(_ text: String, kind: GenerationAIR.Kind, mature: Bool) async throws -> [GenerationModel] {
        var query = [URLQueryItem(name: "limit", value: "30"), URLQueryItem(name: "types", value: kind == .lora ? "LORA" : "Checkpoint"),
                     URLQueryItem(name: "supportsGeneration", value: "true"), URLQueryItem(name: "nsfw", value: mature ? "true" : "false")]
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { query.append(URLQueryItem(name: "sort", value: "Most Downloaded")) } else { query.append(URLQueryItem(name: "query", value: trimmed)) }
        guard let object = try await send(request(Self.site.appendingPathComponent("models"), query: query, authorized: !key.isEmpty)) as? [String: Any],
              let items = object["items"] as? [[String: Any]] else { throw GenerationError.unreadable }
        return items.compactMap { item in
            let versions = item["modelVersions"] as? [[String: Any]] ?? []
            guard let name = item["name"] as? String, let version = versions.first(where: { $0["supportsGeneration"] as? Bool != false }),
                  let id = version["id"] as? Int else { return nil }
            return GenerationModel(air: "", name: [name, version["name"] as? String].compactMap { $0 }.joined(separator: " · "), base: version["baseModel"] as? String, versionID: id)
        }
    }

    // MARK: Generating

    private func workflows(_ prompt: String, _ settings: GenerationSettings, query: [URLQueryItem]) async throws -> GenerationJob {
        let url = Self.service.appendingPathComponent("workflows")
        do {
            return try Self.job(await send(request(url, method: "POST", query: query, body: Self.body(prompt: prompt, settings: settings, field: modelField))))
        } catch GenerationError.invalid(let first) {
            // The service's guide and its schema name the checkpoint field differently; a refusal is retried once under the other name.
            let other = Self.modelFields.first { $0 != modelField } ?? modelField
            do {
                let job = try Self.job(await send(request(url, method: "POST", query: query, body: Self.body(prompt: prompt, settings: settings, field: other))))
                modelField = other
                return job
            } catch GenerationError.invalid { throw GenerationError.invalid(first) }
        }
    }

    /// What the request would cost in Buzz, without running it.
    func estimate(prompt: String, settings: GenerationSettings) async throws -> Double? {
        try await workflows(prompt, settings, query: [URLQueryItem(name: "whatif", value: "true")]).cost
    }

    /// Starts a request and waits a little for it; the job may come back still running.
    func submit(prompt: String, settings: GenerationSettings, wait: Int = 30) async throws -> GenerationJob {
        try await workflows(prompt, settings, query: [URLQueryItem(name: "wait", value: String(wait))])
    }

    func job(_ id: String, wait: Int = 30) async throws -> GenerationJob {
        try Self.job(await send(request(Self.service.appendingPathComponent("workflows/\(id)"), query: [URLQueryItem(name: "wait", value: String(wait))])))
    }

    func cancel(_ id: String) async {
        guard let request = try? request(Self.service.appendingPathComponent("workflows/\(id)"), method: "DELETE") else { return }
        _ = try? await transport(request)
    }

    /// Waits for a job to end, asking again each time the wait runs out, for up to `limit` seconds.
    func finish(_ job: GenerationJob, limit: Double = 300, progress: (@Sendable (GenerationJob) async -> Void)? = nil) async throws -> GenerationJob {
        var current = job
        let began = Date()
        while !current.isFinished {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(began) < limit else { throw GenerationError.failed(L10n.text("The picture is taking too long. It may still finish on Civitai.")) }
            await progress?(current)
            current = try await self.job(current.id)
        }
        return current
    }

    /// The bytes of a finished picture. Its address is already signed, so the key is not sent.
    func picture(_ url: URL) async throws -> Data {
        let (data, response) = try await transport(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode), !data.isEmpty else { throw GenerationError.failed("") }
        return data
    }

    // MARK: Reading answers

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    static func job(_ object: Any) throws -> GenerationJob {
        guard let workflow = object as? [String: Any], let id = workflow["id"] as? String ?? (workflow["cost"] != nil ? "" : nil) else { throw GenerationError.unreadable }
        var job = GenerationJob(id: id, status: workflow["status"] as? String ?? "unassigned")
        job.cost = number((workflow["cost"] as? [String: Any])?["total"]) ?? number(workflow["cost"])
        for step in workflow["steps"] as? [[String: Any]] ?? [] {
            for entry in (step["output"] as? [String: Any])?["images"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                var image = GenerationImage(id: id, url: (entry["url"] as? String).flatMap(URL.init(string:)))
                image.width = entry["width"] as? Int; image.height = entry["height"] as? Int
                image.available = entry["available"] as? Bool ?? (image.url != nil)
                image.blockedReason = entry["blockedReason"] as? String
                job.images.append(image)
            }
            for run in step["jobs"] as? [[String: Any]] ?? [] {
                if let reason = run["reason"] as? String, job.reason == nil { job.reason = reason }
                if let blocked = run["blockedReason"] as? String, job.blockedReason == nil { job.blockedReason = blocked }
            }
        }
        return job
    }

    /// Why a finished job has no picture to show, if it has none.
    static func failure(of job: GenerationJob) -> GenerationError? {
        if job.reason == "blocked" || (job.images.isEmpty && job.blockedReason != nil) { return .blocked(job.blockedReason ?? "") }
        if job.status == "succeeded" {
            if job.images.contains(where: { $0.available && $0.url != nil }) { return nil }
            return job.images.isEmpty ? .failed("") : .failed(L10n.text("The result was withheld. Results rated as mature are only returned when that is allowed."))
        }
        switch job.status {
        case "canceled": return .failed(L10n.text("The request was cancelled."))
        case "expired": return .failed(L10n.text("The request ran out of time. It is safe to try again."))
        default: return .failed(job.reason == "no_provider_available" ? L10n.text("No worker can run this request right now. Try other settings or try later.") : "")
        }
    }
}
