import Foundation
import MM2TCore

/// Prompt text and response schemas for the four LLM tasks. Pure: transcript in, strings and schemas out.
enum GeminiPrompts {
    static let common = """
    你是會議記錄助理。輸入是一場線上會議的逐字稿，多半是台灣華語夾雜英文，也可能整場是英文。逐字稿由語音辨識產生，可能有錯字、同音字與斷句錯誤。

    逐字稿每行的格式是：[發言編號] 說話者代號 時間 內容。發言編號例如 u12；說話者代號例如 {{speaker:r1}}，其中 {{speaker:me}} 是錄音者本人。行首標有「(重點)」的發言是使用者在會議中特別標記的重點。

    共同規則：
    1. 指稱任何人時，只能使用說話者代號，並原樣寫成 {{speaker:代號}}，例如 {{speaker:r2}}。即使逐字稿裡出現人名，也不要用人名取代代號，也不要自創「講者一」「A 先生」之類的稱呼。JSON 的 speaker 與 owner 欄位只填代號本身（例如 r2、me），不加大括號。
    2. 每一項輸出都要在 sources 列出它依據的發言編號（例如 ["u12","u13"]），只能使用逐字稿中出現過的編號。
    3. 輸出語言跟隨逐字稿的主要語言：以華語為主時使用繁體中文與台灣慣用詞（例如「影片」「軟體」「資料庫」「專案」），英文專有名詞、產品名稱與技術術語保留英文原文；整場是英文時使用英文。
    4. 不要加入逐字稿沒有的資訊，也不要猜測。
    """

    static let inferNames = """
    任務：推測指定說話者的真實姓名或常用稱呼。依據逐字稿中的稱呼、自我介紹、點名與回應等線索。只有線索足夠時才列出猜測，沒有把握的說話者就不要列出。已知姓名屬於其他說話者，不要把它們給指定的說話者。name 只填姓名或稱呼本身。reason 用一句話說明依據，提到人時一樣使用 {{speaker:代號}}。
    """

    static let cleanTranscript = """
    任務：把逐字稿整理成乾淨、好讀的文字稿（Typeless 式整理）。
    - 刪除口頭禪與填充詞，例如「嗯」「呃」「那個」「就是」「然後」「對對對」「you know」「like」等沒有意義的部分。
    - 說話者自我修正時，只保留修正後的說法，例如「禮拜三，不對，禮拜四」整理成「禮拜四」。
    - 刪除結巴與無意義的重複。
    - 加上正確的標點並適當分段：中文用全形標點，英文句子用半形標點。
    - 修正明顯的語音辨識錯字；不確定時保留原文。
    - 不要摘要，不要濃縮，不要改寫語意。每一個論點、數字、名稱、承諾、疑問與細節都要保留，內容完整度與原文相同，只是更乾淨。
    - 同一位說話者連續的發言可以合併成一段；不同說話者絕不合併。依原本順序輸出。
    - 每段的 speaker 填該段說話者代號，sources 列出該段涵蓋的所有發言編號。逐字稿中的每一個發言編號都必須出現在某一段的 sources 裡。
    """

    static let digestPerPerson = """
    任務：依說話者整理每個人在這場會議中的重點：提出的觀點、提供的資訊、提出的問題、做出的承諾與被指派的工作。每位有實質發言的說話者一個項目，依首次發言的順序排列。每個重點寫一到兩句，具體寫出內容（數字、名稱、期限）。只有寒暄或附和的說話者可以只列一個重點。
    """

    static let summarize = """
    任務：產生會議摘要。
    - headline：用一到兩句話（不超過 60 個字）說明這場會議談了什麼、得到什麼結論，給會議清單當預覽。直接寫內容，不要以「本次會議」「這場會議」開頭。
    - decisions：會議中確定的決定。
    - discussionPoints：主要討論的議題，以及各方的意見與理由。
    - actionItems：待辦事項。owner 填負責人的說話者代號（例如 r2），沒有明確負責人時填 null。
    標記「(重點)」的發言是使用者特別在意的內容：摘要必須涵蓋每一則重點發言，並把相關項目排在各區塊的最前面。
    """

    static func render(_ utterances: [LLMUtterance]) -> String {
        utterances.map(line).joined(separator: "\n")
    }

    static func line(_ u: LLMUtterance) -> String {
        let seconds = Int(u.range.start)
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        let mark = u.isHighlighted ? "(重點) " : ""
        return "\(mark)[\(u.id.rawValue)] \(SpeakerMention.token(u.speaker)) \(time) \(u.text)"
    }

    static func nameRequest(_ request: NameInferenceRequest) -> String {
        let targets = request.unnamedSpeakers.map { SpeakerMention.token($0) }.joined(separator: "、")
        let known = request.knownNames.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\(SpeakerMention.token($0.key)) = \($0.value)" }
        return """
        要推測的說話者：\(targets)
        已知姓名：\(known.isEmpty ? "（無）" : known.joined(separator: "、"))

        逐字稿：
        \(render(request.transcript.utterances))
        """
    }

    static func summaryRequest(_ request: SummaryRequest) -> String {
        let highlighted = request.prioritized.isEmpty
            ? "（無）" : render(request.prioritized)
        return """
        使用者標記的重點發言：
        \(highlighted)

        完整逐字稿：
        \(render(request.transcript.utterances))
        """
    }

    // MARK: Schemas

    static func nameSchema(_ speakers: [SpeakerID]) -> JSON {
        .object([("guesses", .array(of: .object([
            ("speaker", speakerEnum(speakers)),
            ("name", .string),
            ("reason", .string),
        ])))])
    }

    static func cleanSchema(_ speakers: [SpeakerID]) -> JSON {
        .object([("paragraphs", .array(of: .object([
            ("speaker", speakerEnum(speakers)),
            ("text", .string),
            ("sources", .array(of: .string)),
        ])))])
    }

    static func digestSchema(_ speakers: [SpeakerID]) -> JSON {
        .object([("digests", .array(of: .object([
            ("speaker", speakerEnum(speakers)),
            ("points", .array(of: sourcedText)),
        ])))])
    }

    static func summarySchema(_ speakers: [SpeakerID]) -> JSON {
        .object([
            ("headline", .string),
            ("decisions", .array(of: sourcedText)),
            ("discussionPoints", .array(of: sourcedText)),
            ("actionItems", .array(of: .object([
                ("text", .string),
                ("owner", .dict([("type", .list([.text("string"), .text("null")]))])),
                ("sources", .array(of: .string)),
            ]))),
        ])
    }

    private static let sourcedText = JSON.object([("text", .string), ("sources", .array(of: .string))])

    private static func speakerEnum(_ speakers: [SpeakerID]) -> JSON {
        .dict([("type", .text("string")), ("enum", .list(speakers.map { .text($0.rawValue) }))])
    }
}

/// Minimal JSON value with ordered object keys; Gemini emits properties in schema order.
indirect enum JSON: Sendable {
    case text(String)
    case list([JSON])
    case dict([(String, JSON)])

    static let string = JSON.dict([("type", .text("string"))])

    static func array(of items: JSON) -> JSON {
        .dict([("type", .text("array")), ("items", items)])
    }

    /// An object schema whose properties are all required.
    static func object(_ properties: [(String, JSON)]) -> JSON {
        .dict([
            ("type", .text("object")),
            ("properties", .dict(properties)),
            ("required", .list(properties.map { .text($0.0) })),
        ])
    }

    func serialized() -> String {
        switch self {
        case .text(let value):
            let data = try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            return String(decoding: data, as: UTF8.self)
        case .list(let items):
            return "[" + items.map { $0.serialized() }.joined(separator: ",") + "]"
        case .dict(let pairs):
            return "{" + pairs.map { JSON.text($0.0).serialized() + ":" + $0.1.serialized() }.joined(separator: ",") + "}"
        }
    }
}
