import Foundation
import MM2TCore

/// Prompt text and response schemas for the four LLM tasks. Pure: transcript in, strings and schemas out.
package enum LLMPrompts {
    static let common = """
    你是會議記錄助理。輸入是一場線上會議的逐字稿，多半是台灣華語夾雜英文，也可能整場是英文。逐字稿由語音辨識產生，可能有錯字、同音字與斷句錯誤。

    逐字稿每行的格式是：[發言編號] 說話者代號 時間 內容。發言編號例如 u12；說話者代號例如 {{speaker:r1}}，其中 {{speaker:me}} 是錄音者本人。行首標有「(重點)」的發言是使用者在會議中特別標記的重點。

    共同規則：
    1. 指稱任何人時，只能使用說話者代號，並原樣寫成 {{speaker:代號}}，例如 {{speaker:r2}}。即使逐字稿裡出現人名，也不要用人名取代代號，也不要自創「講者一」「A 先生」之類的稱呼。在文字內容裡一律要有大括號，例如寫「由 {{speaker:r1}} 負責」，不能寫「由 r1 負責」。JSON 的 speaker 與 owner 欄位只填代號本身（例如 r2、me），不加大括號。
    2. 每一項輸出都要在 sources 列出它依據的發言編號（例如 ["u12","u13"]），只能使用逐字稿中出現過的編號。
    3. 輸出只能使用兩種語言：繁體中文與英文。以華語為主時使用繁體中文與台灣慣用詞（例如「影片」「軟體」「資料庫」「專案」「品質」），英文專有名詞、產品名稱與技術術語保留英文原文；整場是英文時使用英文。絕對不可以出現簡體字或中國大陸用語（「视频」「軟件」「數據庫」「項目」「質量」都不行），也不要輸出其他語言。
    4. 不要加入逐字稿沒有的資訊，也不要猜測。
    """

    static let inferNames = """
    任務：推測指定說話者的真實姓名或常用稱呼。依據逐字稿中的稱呼、自我介紹、點名與回應等線索。只有線索足夠時才列出猜測，沒有把握的說話者就不要列出。已知姓名屬於其他說話者，不要把它們給指定的說話者。name 只填姓名或稱呼本身。reason 用一句話說明依據，提到人時一樣使用 {{speaker:代號}}。
    """

    static let cleanTranscript = """
    任務：把語音辨識的逐字稿改寫成「這個人如果用打字的，會打出來的樣子」。讀者要的是每位說話者最後想表達的意思，不是他嘴巴發出的每一個音。輸入是口語，而且有辨識錯誤；你要像一位熟悉這場會議的編輯，先聽懂，再寫下來。

    怎麼改：
    1. 先理解再下筆。整段讀完，弄清楚這個人想說什麼，再寫成通順的書面句子。口語的倒裝、斷掉重來的半句、沒講完就換話題的殘句，都整理成完整的句子；真的聽不出意思的殘句就刪掉。
    2. 刪掉贅詞與墊話：「嗯」「呃」「那個」「就是」「就是說」「然後」「對對對」「其實」「基本上」「you know」「like」「I mean」。這些詞有實際意思時要留下（「然後」表示先後順序、「就是」用來下定義）。
    3. 改口只留最後的說法。「三月，不對，四月」寫成「四月」；「我們先做 A……還是先做 B 好了」寫成「我們先做 B」。只處理同一位說話者自己的改口；別人說「不對」是反駁，必須保留。
    4. 結巴與重複只留一次：「我我我覺得」「這個這個功能」。為了強調而重複的話留下。
    5. 用上下文修正辨識錯誤：同音字、被拆開的英文詞、被寫成中文諧音的英文術語（「酷柏內提斯」是 Kubernetes）。「詞彙表」列出這位使用者常用的人名、產品名與術語；逐字稿裡讀音相近的字詞，一律改成詞彙表的寫法。沒有把握時保留原文，不要猜。
    6. 只有在說話者明確列舉時（「第一……第二……」「首先……再來……最後……」「有三件事」）才排成清單，每項一行，以「1. 」「2. 」開頭。其他內容照意思分段，一段講一件事，段落之間空一行。
    7. 標點與格式：中文用全形標點，英文句子用半形標點；中文與英文、數字之間留一個半形空格（「升級 Kubernetes 到 1.31 版」）。數字、日期、時間、金額、百分比用阿拉伯數字（「百分之二十」寫成「20%」、「三點半」寫成「3:30」），數值本身不可更動。
    8. 英文專有名詞、產品名稱與技術術語保留英文原文，不要翻譯；大小寫用正式寫法（iPhone、GitHub、API）。

    不可以做的事：
    - 不要摘要、不要濃縮。每一個論點、數字、名稱、承諾、疑問與理由都要留下，資訊量與原文相同。
    - 不要加入沒說過的內容，不要替說話者下結論，不要把內容從一位說話者搬到另一位。
    - 不要改變立場與語氣強弱：猶豫（「可能」「我不確定」）、保留、反對都要看得出來。

    範例（只示範改寫方式，不是這場會議的內容）：
    原文：「嗯那個我覺得就是我們這個這個 Q3 的那個目標喔，其實應該是要放在那個留存率，對，留存率上面，然後不是新用戶」
    整理：「我覺得 Q3 的目標應該放在留存率，而不是新用戶。」
    原文：「我們禮拜三，不對，禮拜四之前會把 cluster 升級完，然後呃 rollback plan 的話小華你寫一下」
    整理：「我們禮拜四之前會把 cluster 升級完。Rollback plan 請小華寫。」
    原文：「所以現在有三件事要做啦，第一個就是那個 API 的文件要補，再來是測試覆蓋率要拉到百分之八十，最後就是要跟設計那邊確認一下時程」
    整理：「現在有三件事要做：\n1. 補 API 文件。\n2. 把測試覆蓋率拉到 80%。\n3. 跟設計確認時程。」
    原文：「這個我不太確定欸，可能，可能要再看一下數據，我是覺得不要那麼快決定」
    整理：「這個我不太確定，可能要再看一下數據。我覺得不要那麼快決定。」

    輸出：
    - 同一位說話者連續的發言合併成一段；中間只是別人附和（「嗯」「對」「OK」）時，附和可以省略，前後仍算同一段。不同說話者的內容絕不合併。依原本順序輸出。
    - 每段的 speaker 填該段說話者代號，sources 列出該段涵蓋的所有發言編號。「前文」只供你理解脈絡，不要輸出，也不要列進 sources。
    - 整段只有贅詞或附和、沒有內容的發言可以不輸出。
    """

    static let digestPerPerson = """
    任務：依說話者整理每個人在這場會議中的重點：提出的觀點、提供的資訊、提出的問題、做出的承諾與被指派的工作。每位有實質發言的說話者一個項目，依首次發言的順序排列。每個重點寫一到兩句，具體寫出內容（數字、名稱、期限）。只有寒暄或附和的說話者可以只列一個重點。
    """

    static let summarize = """
    任務：產生會議摘要。
    - title：這場會議的標題，像行事曆上會寫的名稱，不超過 20 個字，直接點出主題（例如「Q3 留存率目標檢討」「Kubernetes 升級排程」）。不要寫日期，不要用「會議」「討論」「錄音」這類空泛的字當主體，不要加標點或引號，不要用說話者代號。
    - terms：逐字稿中出現、值得記進使用者詞彙表的專有名詞，最多 12 個：人名、公司與產品名稱、專案代號、縮寫、領域術語。寫成正確的寫法與大小寫。一般詞彙（「會議」「進度」「系統」）不要列；沒有就給空陣列。
    - headline：用一到兩句話（不超過 60 個字）說明這場會議談了什麼、得到什麼結論，給會議清單當預覽。直接寫內容，不要以「本次會議」「這場會議」開頭。
    - decisions：會議中確定的決定。
    - discussionPoints：主要討論的議題，以及各方的意見與理由。
    - actionItems：待辦事項。owner 填負責人的說話者代號（例如 r2），沒有明確負責人時填 null。
    標記「(重點)」的發言是使用者特別在意的內容：摘要必須涵蓋每一則重點發言，並把相關項目排在各區塊的最前面。
    """

    /// Appended to the system prompt of an English meeting. The prompts are written in Chinese, and a
    /// model reading them answers in Chinese unless the output language is stated outright.
    static let englishOutput = """
    Output language: English. This meeting is in English, so write every text you produce in English \
    (title, headline, terms, decisions, discussion points, action items, digests, cleaned paragraphs, \
    reasons), even though these instructions are written in Chinese. Keep the {{speaker:…}} tokens as they are.
    """

    /// A meeting counts as English when Chinese characters are under 5% of its words. A Latin word is
    /// about five letters and a Chinese character about one word, so a Mandarin meeting full of
    /// English terms stays Chinese.
    static func isEnglish(_ utterances: [LLMUtterance]) -> Bool {
        var cjk = 0, latin = 0
        for scalar in utterances.lazy.flatMap(\.text.unicodeScalars) {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: cjk += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        let words = Double(cjk) + Double(latin) / 5
        return words > 0 && Double(cjk) < words * 0.05
    }

    static func system(_ task: String, for utterances: [LLMUtterance]) -> String {
        let base = common + "\n\n" + task
        return isEnglish(utterances) ? base + "\n\n" + englishOutput : base
    }

    static func render(_ utterances: [LLMUtterance]) -> String {
        utterances.map(line).joined(separator: "\n")
    }

    static func line(_ u: LLMUtterance) -> String {
        let seconds = Int(u.range.start)
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        let mark = u.isHighlighted ? "(重點) " : ""
        return "\(mark)[\(u.id.rawValue)] \(SpeakerMention.token(u.speaker)) \(time) \(u.text)"
    }

    /// One chunk of the transcript to clean, with the lines before it for context and the user's glossary.
    static func cleanRequest(_ chunk: [LLMUtterance], context: [LLMUtterance], glossary: [String]) -> String {
        var parts: [String] = []
        if !glossary.isEmpty { parts.append("詞彙表：\n" + glossary.joined(separator: "、")) }
        if !context.isEmpty { parts.append("前文（只供理解，不要輸出）：\n" + render(context)) }
        parts.append("逐字稿：\n" + render(chunk))
        return parts.joined(separator: "\n\n")
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
            ("title", .string),
            ("terms", .array(of: .string)),
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

/// Minimal JSON value with ordered object keys; models emit properties in schema order.
package indirect enum JSON: Sendable {
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
