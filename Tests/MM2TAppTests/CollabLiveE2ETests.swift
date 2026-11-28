import Foundation
@testable import MM2TApp
import MM2TCore
import MM2TDiarization
import MM2TLocal
import MM2TProviders
import Testing

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MM2T_LIVE_E2E"] == "1",
                "Set MM2T_LIVE_E2E=1 to run against the live development backend"))
struct CollabLiveE2E {
    @Test func standardHostTurnsMeetingIntoSharedComponents() async throws {
        let environment = ProcessInfo.processInfo.environment
        let api = try #require(URL(string: environment["MM2T_COLLAB_API_URL"] ?? "http://localhost:8080"))
        let web = try #require(URL(string: environment["MM2T_COLLAB_WEB_URL"] ?? "http://localhost:3000"))
        let output = URL(fileURLWithPath: environment["MM2T_E2E_OUT"] ??
            "/private/tmp/claude-501/-Volumes-KINGSTON-yuzen-code-mm2t/145790c2-367d-444b-9519-b4fbd5377ef1/scratchpad/e2e-report.json")
        let start = Date()
        let llmCalls = Box<[Call]>([])
        var report = Report()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.protocolClasses = [ObserveCreate.self]
        ObserveCreate.sources.set([])
        let http = URLSession(configuration: config)
        defer { http.finishTasksAndInvalidate() }

        func elapsed() -> Double { Date().timeIntervalSince(start) }
        func check(_ name: String, _ pass: Bool) {
            report.assertions[name] = pass
            #expect(pass, Comment(rawValue: name))
        }
        func request(_ path: String, method: String = "GET", token: String? = nil,
                     json: [String: String]? = nil) async throws -> (Data, Int) {
            var request = URLRequest(url: api.appending(path: path))
            request.httpMethod = method
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(json)
            }
            let (data, response) = try await http.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        func signIn(_ email: String, _ name: String) async throws -> Login {
            let (data, status) = try await request("v1/auth/dev", method: "POST", json: ["email": email, "name": name])
            guard status == 200 else { throw ProbeError.http("dev sign-in", status) }
            return try JSONDecoder().decode(Login.self, from: data)
        }
        func hostedError(_ data: Data) -> String? {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (body?["error"] as? [String: Any])?["code"] as? String
        }

        do {
            let login = try await signIn("e2e-host@mm2t.test", "E2E 主持人")
            let root = output.deletingLastPathComponent().appending(path: "collab-\(UUID())")
            let credentials = MemoryCredentials()
            try login.install(in: credentials, api: api)
            let account = CollabAccount(configuration: .init(apiURL: api, webURL: web), credentials: credentials,
                                        pendingEndsFile: root.appending(path: "pending-ends.json"), session: http)
            let before = try await account.service.me()
            await account.refreshProfile()
            check("standardActiveWithQuotaAvailable", before.plan?.name == "standard" && before.plan?.status == "active"
                  && before.quota.limit == 10 && before.quota.used < before.quota.limit)
            guard report.assertions["standardActiveWithQuotaAvailable"] == true else { throw ProbeError.preflight }
            report.quotaBefore = before.quota.used
            report.quotaLimit = before.quota.limit

            let free = try await signIn("e2e-free@mm2t.test", "E2E 免費使用者")
            let freeCredentials = MemoryCredentials()
            try free.install(in: freeCredentials, api: api)
            let freeService = CollabService(baseURL: api, session: http,
                load: { try freeCredentials.read(.collabAccount) }, save: { try freeCredentials.save($0, for: .collabAccount) })
            let freeProfile = try await freeService.me()
            check("freeProfile", freeProfile.plan?.name == "free")
            if freeProfile.plan?.name == "free" {
                do {
                    _ = try await freeService.createRoom(title: "E2E Free plan gate", owner: free.user.id, aiSource: .hosted)
                    check("freeCreateMapsPlanRequired", false)
                } catch {
                    check("freeCreateMapsPlanRequired", error as? CollabError == .planRequired)
                    if error as? CollabError != .planRequired { report.errors.append("Free create: \(error)") }
                }
            }

            let (lease, leaseStatus) = try await request("v1/hosted/sessions", method: "POST", token: login.accessToken)
            report.hostedSessionStatus = leaseStatus
            report.hostedSessionError = hostedError(lease)
            if leaseStatus == 503 && report.hostedSessionError == "unavailable" {
                check("hostedSessionUnavailable", true)
                report.captionsNotRun = "Session creation returned 503 unavailable; no lease ID was issued for /captions."
            } else if (200..<300).contains(leaseStatus) {
                struct Lease: Decodable { let id: UUID }
                let id = try JSONDecoder().decode(Lease.self, from: lease).id.uuidString.lowercased()
                do {
                    let (captions, status) = try await request("v1/hosted/sessions/\(id)/captions", method: "POST", token: login.accessToken)
                    report.captionsStatus = status
                    report.captionsError = hostedError(captions)
                    check("hostedCaptionsUnavailable", status == 503 && report.captionsError == "unavailable")
                } catch {
                    _ = try? await request("v1/hosted/sessions/\(id)/finish", method: "POST", token: login.accessToken)
                    throw error
                }
                let (_, finishStatus) = try await request("v1/hosted/sessions/\(id)/finish", method: "POST", token: login.accessToken)
                guard (200..<300).contains(finishStatus) else { throw ProbeError.http("finish test lease", finishStatus) }
            } else {
                check("hostedSessionUnavailable", false)
                report.captionsNotRun = "Unexpected hosted session response; no lease ID was issued for /captions."
            }

            let models = root.appending(path: "models")
            let setup = PipelineSetup(library: MeetingLibrary(root: root), voiceprints: try VoiceprintStore(fileURL: root.appending(path: "voiceprints.json")),
                credentials: credentials, catalog: LiveProviderCatalog(models: DiarizationModels(directory: models),
                    transcriptionModel: .breezeMLX(in: models), translationModels: TranslationModels(directory: models, directions: [])),
                account: account.service)
            var settings = AppSettings()
            settings.summaryService = .mm2t
            let snapshot = settings
            let clock = Box(Date())
            let session = CollabSession(account: account, title: "E2E｜新品上市協作", now: { clock.get }) {
                (snapshot.summaryService == .mm2t ? .hosted : .own, {
                    let build = try setup.buildLLM(snapshot, accountURL: api)
                    if case .ready(let provider) = build { return .ready(ObservedLLM(provider: provider, calls: llmCalls)) }
                    return build
                })
            }
            let captions = LiveCaptions(now: { clock.get })
            captions.set(.live)
            session.captionsActive = { captions.isActive }
            captions.onFinalized = { [weak session] in session?.finalized($0) }

            func feed(_ lines: [String], step: TimeInterval) async throws {
                for line in lines {
                    clock.update { $0.addTimeInterval(step) }
                    captions.receive(.final(line))
                    try await Task.sleep(for: .milliseconds(30))
                }
                await session.waitForWork()
            }

            // Sharing is initiated by the first command in the UI. Use a separate action item as the seed.
            try await feed(Self.opening, step: 0.5)
            session.run(command: "建立開場待辦清單：怡君今天寄上市會議通知給專案組。不要建立其他類型的元件。")
            check("uiRequestsShareConfirmation", session.state == .confirmingStart)
            ObserveCreate.sources.set([])
            session.startSharing()
            let deadline = ContinuousClock.now + .seconds(30)
            while session.state == .starting && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            report.createAISource = ObserveCreate.sources.get.last
            check("createRequestUsesHostedAI", report.createAISource == "hosted")
            guard let room = session.room else {
                throw ProbeError.session("room creation", String(reflecting: session.commandStatus))
            }
            report.roomID = room.roomId
            var share = URLComponents(url: room.shareUrl, resolvingAgainstBaseURL: false)
            share?.fragment = nil
            report.shareURL = share?.url?.absoluteString
            report.timings["roomLive"] = elapsed()
            let after = try await account.service.me()
            report.quotaAfter = after.quota.used
            check("quotaUsedIncreasedByOne", after.quota.period == before.quota.period && after.quota.used == before.quota.used + 1)
            func components() async throws -> CollabRoomComponents {
                try await account.service.components(in: room.roomId, owner: login.user.id)
            }
            await session.waitForWork()
            report.baseline = try await components().components
            if case .failed(let failure) = session.commandStatus { report.errors.append("Opening command: \(failure)") }
            let hideDeadline = ContinuousClock.now + .seconds(3)
            while session.commandStatus != .hidden && ContinuousClock.now < hideDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            check("readyForAutomaticSuggestions", session.commandStatus == .hidden)

            for (kind, lines, _) in Self.topics {
                // Keep the full meeting in the command window and give each topic an automatic observation window.
                try await feed(lines, step: 0.5)
                clock.update { $0.addTimeInterval(report.suggestions.isEmpty ? 21 : 61) }
                captions.receive(.final("怡君：這一段先整理到這裡，大家還有要補充的嗎？"))
                await session.waitForWork()
                if let offer = session.suggestion {
                    report.suggestions.append(.init(topic: kind, kind: offer.kind, title: offer.title, atSeconds: elapsed()))
                    session.dismissSuggestion()
                }
            }
            report.automatic = try await components().components
            report.timings["automaticObserved"] = elapsed()

            for (kind, _, command) in Self.topics where !report.automatic.contains(where: { $0.kind == kind && !$0.building }) {
                let began = elapsed()
                session.run(command: command)
                if case .building = session.commandStatus {
                    await session.waitForWork()
                } else {
                    report.errors.append("\(kind.rawValue) command was not accepted by CollabSession")
                }
                report.timings["command.\(kind.rawValue)"] = elapsed() - began
                if case .failed(let failure) = session.commandStatus { report.errors.append("\(kind.rawValue) command: \(failure)") }
            }
            let end = try await components()
            report.components = end.components
            check("roomStillLive", end.status == .live)
            check("ganttDatesAndDependencies", end.components.contains(where: Self.validGantt))
            check("pollOptions", end.components.contains(where: Self.validPoll))
            check("approvalFlowWithThresholdAndRejection", end.components.contains(where: Self.validFlow))
        } catch {
            report.errors.append(String(reflecting: error))
            Issue.record(error)
        }
        report.llmCalls = llmCalls.get
        report.llmCallCount = report.llmCalls.count
        report.timings["total"] = elapsed()
        for name in ["standardActiveWithQuotaAvailable", "freeProfile", "freeCreateMapsPlanRequired", "hostedCaptionsUnavailable",
                     "uiRequestsShareConfirmation", "createRequestUsesHostedAI", "quotaUsedIncreasedByOne", "readyForAutomaticSuggestions", "roomStillLive",
                     "ganttDatesAndDependencies", "pollOptions", "approvalFlowWithThresholdAndRejection"] where report.assertions[name] == nil {
            report.notRun.append(name)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private struct Login: Codable {
        let accessToken: String
        let refreshToken: String
        let user: CollabUser

        func install(in credentials: MemoryCredentials, api: URL) throws {
            struct Stored: Encodable {
                struct Tokens: Encodable { let accessToken: String; let refreshToken: String }
                let apiURL: URL
                let tokens: Tokens
                let user: CollabUser
            }
            let stored = Stored(apiURL: api, tokens: .init(accessToken: accessToken, refreshToken: refreshToken), user: user)
            let data = try JSONEncoder().encode(stored)
            try credentials.save(Secret(String(decoding: data, as: UTF8.self)), for: .collabAccount)
        }
    }

    private enum ProbeError: Error {
        case preflight, http(String, Int), session(String, String), callLimit
    }

    private struct Report: Encodable {
        var roomID: String?
        var shareURL: String?
        var createAISource: String?
        var quotaBefore: Int?
        var quotaAfter: Int?
        var quotaLimit: Int?
        var hostedSessionStatus: Int?
        var hostedSessionError: String?
        var captionsStatus: Int?
        var captionsError: String?
        var captionsNotRun: String?
        var baseline: [CollabComponent] = []
        var automatic: [CollabComponent] = []
        var components: [CollabComponent] = []
        var suggestions: [Offer] = []
        var timings: [String: Double] = [:]
        var llmCallCount = 0
        var llmCalls: [Call] = []
        var errors: [String] = []
        var assertions: [String: Bool] = [:]
        var notRun: [String] = []
    }

    private struct Offer: Encodable {
        let topic: CollabComponentKind
        let kind: CollabComponentKind
        let title: String
        let atSeconds: Double
    }

    private struct Call: Encodable {
        let purpose: String
        var seconds: Double?
        var output = ""
        var error: String?
    }

    private struct ObservedLLM: LLMProvider {
        let provider: any LLMProvider
        let calls: Box<[Call]>
        func forGeneration() async -> any LLMProvider { Self(provider: await provider.forGeneration(), calls: calls) }
        func streamText(system: String, input: String) -> AsyncThrowingStream<String, Error> {
            let purpose = system == CollabPrompts.suggestion ? "suggestion" : system == CollabPrompts.update ? "update" : "command"
            return AsyncThrowingStream { continuation in
                let task = Task {
                    let began = Date()
                    var index: Int?
                    calls.update {
                        if $0.count < 16 { index = $0.count; $0.append(Call(purpose: purpose)) }
                    }
                    guard let index else { continuation.finish(throwing: ProbeError.callLimit); return }
                    do {
                        for try await fragment in provider.streamText(system: system, input: input) {
                            calls.update { $0[index].output += String(fragment.prefix(max(0, 16_000 - $0[index].output.count))) }
                            continuation.yield(fragment)
                        }
                        calls.update { $0[index].seconds = Date().timeIntervalSince(began) }
                        continuation.finish()
                    } catch {
                        calls.update {
                            $0[index].seconds = Date().timeIntervalSince(began)
                            $0[index].error = String(reflecting: error)
                        }
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        func generateText(system: String, input: String) async throws -> String { try await provider.generateText(system: system, input: input) }
        func inferNames(_ request: NameInferenceRequest) async throws -> [NameGuess] { try await provider.inferNames(request) }
        func cleanTranscript(_ transcript: LLMTranscript) async throws -> CleanedTranscript { try await provider.cleanTranscript(transcript) }
        func digestPerPerson(_ transcript: LLMTranscript) async throws -> [PersonDigest] { try await provider.digestPerPerson(transcript) }
        func summarize(_ request: SummaryRequest) async throws -> Summary { try await provider.summarize(request) }
        func rewrite(_ text: String, instruction: String) async throws -> String { try await provider.rewrite(text, instruction: instruction) }
        func vocabularyCorrections(from old: String, to new: String) async throws -> [VocabularyCorrection] {
            try await provider.vocabularyCorrections(from: old, to: new)
        }
    }

    // Observe only the room-create body; the real endpoint handles it and returns the real room.
    private final class ObserveCreate: URLProtocol, @unchecked Sendable {
        static let sources = Box<[String]>([])
        private let forwardingTask = Box<URLSessionDataTask?>(nil)
        private static let upstream: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            return URLSession(configuration: config)
        }()
        override class func canInit(with request: URLRequest) -> Bool {
            request.httpMethod == "POST" && request.url?.path.hasSuffix("/v1/rooms") == true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var outgoing = request
            if outgoing.httpBody == nil, let stream = outgoing.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 {
                        client?.urlProtocol(self, didFailWithError: stream.streamError ?? URLError(.cannotDecodeRawData))
                        return
                    }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                outgoing.httpBody = body
            }
            let fields = outgoing.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            Self.sources.update { $0.append(fields?["aiSource"] ?? "<missing>") }
            let forwarding = Self.upstream.dataTask(with: outgoing) { [weak self] data, response, error in
                guard let self, let client else { return }
                if let error { client.urlProtocol(self, didFailWithError: error); return }
                if let response { client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
                if let data { client.urlProtocol(self, didLoad: data) }
                client.urlProtocolDidFinishLoading(self)
            }
            forwardingTask.set(forwarding)
            forwarding.resume()
        }
        override func stopLoading() { forwardingTask.get?.cancel() }
    }

    private static func text(_ item: [String: CollabJSON], _ key: String) -> String {
        guard case .string(let value) = item[key] else { return "" }
        return value
    }

    private static func validGantt(_ component: CollabComponent) -> Bool {
        guard component.kind == .gantt, !component.building, let tasks = component.itemsByWireID[.tasks], tasks.count >= 3 else { return false }
        let schedule = [(["設計", "design"], "2026-12-01", "2026-12-10"),
                        (["開發", "development"], "2026-12-11", "2026-12-31"),
                        (["測試", "test"], "2027-01-01", "2027-01-14"),
                        (["上線", "上市", "launch", "上架"], "2027-01-20", "2027-01-20")]
        var previous: String?
        for (names, start, end) in schedule {
            let match = tasks.first { id, task in
                let title = text(task, "name").lowercased()
                guard names.contains(where: title.contains), text(task, "start") == start, text(task, "end") == end else { return false }
                guard let previous else { return true }
                guard case .array(let dependencies) = task["dependsOn"] else { return false }
                return dependencies.contains(.string(previous))
            }
            guard let match else { return false }
            previous = String(decoding: match.key, as: UTF8.self)
        }
        return true
    }

    private static func validPoll(_ component: CollabComponent) -> Bool {
        guard component.kind == .poll, !component.building, let options = component.itemsByWireID[.options] else { return false }
        let categories = Set(options.values.compactMap { option -> String? in
            let label = text(option, "label").replacingOccurrences(of: "臺", with: "台")
            if label.contains("混合") || label.contains("並行") || label.contains("兩者") ||
                (label.contains("線上") && (label.contains("台北") || label.contains("實體"))) { return "both" }
            if label.contains("台北") { return "taipei" }
            if label.contains("線上") { return "online" }
            return nil
        })
        return categories.count >= 2
    }

    private static func validFlow(_ component: CollabComponent) -> Bool {
        guard component.kind == .whiteboard, !component.building, let nodes = component.itemsByWireID[.nodes], nodes.count >= 4,
              let edges = component.itemsByWireID[.edges], edges.count >= 3 else { return false }
        func ids(_ predicate: (String) -> Bool) -> Set<String> {
            Set(nodes.filter { predicate(text($0.value, "label")) }.keys.map { String(decoding: $0, as: UTF8.self) })
        }
        let submit = ids { $0.contains("送件") || $0.contains("提交") || $0.contains("提出申請") }
        let manager = ids { $0.contains("主管") }
        let finance = ids { $0.contains("財務") }
        let payment = ids { $0.contains("付款") || $0.contains("撥款") }
        let rejected = ids { $0.contains("退回") || $0.contains("駁回") || $0.contains("不通過") || $0.contains("補件") }
        func threshold(_ label: String) -> Bool {
            let normalized = label.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
            return normalized.contains("50000") || normalized.contains("5萬") || normalized.contains("五萬")
        }
        func lowerBranch(_ label: String) -> Bool {
            ["以下", "以內", "不超過", "未超過", "小於或等於", "≤", "<="].contains(where: label.contains)
        }
        func higherBranch(_ label: String) -> Bool {
            !lowerBranch(label) && ![">=", "≥", "以上", "大於或等於"].contains(where: label.contains) &&
                ["超過", "大於", ">"].contains(where: label.contains)
        }
        let decision = ids { threshold($0) && higherBranch($0) }.subtracting(finance)
        let links = edges.values.map { (text($0, "from"), text($0, "to"), text($0, "label")) }
        func connect(_ from: Set<String>, _ to: Set<String>, label: (String) -> Bool = { _ in true }) -> Bool {
            links.contains { from.contains($0.0) && to.contains($0.1) && label($0.2) }
        }
        let splitDecision = connect(manager, decision) && connect(decision, finance) { label in
            higherBranch(label) || ["是", "yes"].contains(label.lowercased())
        } && connect(decision, payment) { label in
            lowerBranch(label) || ["否", "no"].contains(label.lowercased())
        }
        let splitDirect = connect(manager, finance) { threshold($0) && higherBranch($0) } &&
            connect(manager, payment) { threshold($0) && lowerBranch($0) }
        func returnsToSubmit(_ review: Set<String>) -> Bool {
            connect(review, submit) { label in
                ["退回", "駁回", "否決", "不通過", "不核", "未通過", "未核"].contains(where: label.contains)
            } || (connect(review, rejected) && connect(rejected, submit))
        }
        return connect(submit, manager) && (splitDecision || splitDirect) && connect(finance, payment) &&
            returnsToSubmit(manager) && returnsToSubmit(finance)
    }

    private static let opening = [
        "怡君：早安，我們今天把新品上市的時程、活動和報帳方式都對一下。",
        "承翰：好，先確定大家現在手上的版本一樣。",
        "雅婷：我把上一場的需求單開著，有差異可以當場確認。",
        "怡君：我會在今天把上市會議通知寄給專案組，這是我的開場待辦。"
    ]

    private static let topics: [(CollabComponentKind, [String], String)] = [
        (.gantt, [
            "怡君：先談產品上市排程。設計從 2026 年 12 月 1 日到 12 月 10 日。",
            "雅婷：我負責設計，十號下班前會把定稿交給承翰。",
            "承翰：開發要等設計結束，12 月 11 日才能開始。",
            "承翰：我負責開發，結束日是 2026 年 12 月 31 日，不是隔年才交。",
            "雅婷：測試等開發做完，下一天 2027 年 1 月 1 日開始。",
            "怡君：測試做兩週，一月十四日結束，由雅婷負責驗收。",
            "承翰：好，開發沒完成，測試就不能開始。",
            "雅婷：測試通過才上線，正式上線是 2027 年 1 月 20 日。",
            "怡君：上線是一天的里程碑，起訖都填一月二十日，我負責。",
            "承翰：設計完才開發、開發完才測試、測試通過才上線。",
            "怡君：對，大家需要一張圖看得出四個階段各自的日期和前後依賴。"
        ], "幫我做一個甘特圖，從逐字稿找出設計、開發、測試和上線各自的起訖日期與前置依賴，不要補編日期。"),
        (.poll, [
            "怡君：接著談上市活動的形式，目前還沒有決定。",
            "雅婷：第一個選項是在台北辦實體發表會，媒體比較方便來。",
            "承翰：第二個選項是全線上直播，不用另外租場地。",
            "怡君：第三個選項是台北實體加線上直播，同步舉辦。",
            "雅婷：混合的話要多找一個人顧直播，我可以先問窗口。",
            "承翰：如果選線上，我會先把產品示範的影片剪好。",
            "怡君：台北實體、全線上、兩者並行，這三案都先留著。",
            "雅婷：我們不要先拍板，讓團隊每人投一票。",
            "承翰：同意，一人選一個，票數出來再決定。",
            "怡君：問題就是『上市活動要採用哪一種形式？』。",
            "雅婷：投票關閉之後我再確認場地，我負責跟進。"
        ], "請發起上市活動形式的投票，使用逐字稿裡尚未決定的選項，每人選一案。"),
        (.whiteboard, [
            "怡君：最後談活動費用的報帳審核流程。",
            "雅婷：同事先填報帳申請、附發票，然後送件。",
            "承翰：送件之後由主管審核，所有金額都要先過主管。",
            "怡君：主管如果不通過，就退回申請人補資料，再送件。",
            "雅婷：主管通過之後，不是每張都要跑財務對吧？",
            "怡君：對，金額超過新台幣五萬元才送財務審核。",
            "承翰：新台幣 50,000 元整或以下，主管通過就直接付款。",
            "雅婷：超過 NT$50,000 的案子，要財務審核通過才付款。",
            "承翰：財務如果不通過，也退回申請人補資料，再送件。",
            "怡君：好，付款是終點；退回要畫一條線回到送件。",
            "雅婷：麻煩把五萬元的兩條分支畫清楚，我負責把流程公告給團隊。",
            "承翰：我再更新報帳表單上的附件說明，明天下班前完成。"
        ], "在白板畫出逐字稿中的報帳流程圖。呈現送件、主管審核、NT$50,000 金額判斷、財務審核、付款，以及審核退回後重新送件的連線。")
    ]
}
