import Foundation
import Security

// MARK: - Verdicts

/// Prosecutor: searches the web and judges the claim.
struct Verdict: Codable, Equatable {
    var verdict: String        // true | false | misleading | unverifiable
    var confidence: Double
    var correction: String     // what is actually true, one short line
    var source: String?
    var flagged: Bool { ["false", "misleading"].contains(verdict.lowercased()) && confidence >= 0.7 }
}

/// Defender: independently searches for the strongest case that the claim is fine.
struct Defense: Codable, Equatable {
    var defensible: Bool
    var confidence: Double
    var reason: String
    var source: String?
}

enum Outcome: Equatable { case checking, bs, ok, unsure, overturned, failed }

enum FactCheck {
    static let model = ProcessInfo.processInfo.environment["BS_MODEL"] ?? "gpt-4.1-mini"               // claim extraction, no search
    static let judgeModel = ProcessInfo.processInfo.environment["BS_JUDGE_MODEL"] ?? "gpt-4.1-mini"    // prosecutor + defender

    /// No agent signs off on its own work: BS needs the prosecutor to flag it AND the defender to fail to defend it.
    static func outcome(_ v: Verdict, _ d: Defense?) -> Outcome {
        if v.flagged { return d.map { !$0.defensible && $0.confidence >= 0.6 } == true ? .bs : .overturned }
        return v.verdict.lowercased() == "true" ? .ok : .unsure
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// Pulls checkable factual claims out of the newest thing someone said. Usually returns nothing.
    static func claims(in text: String, speaker: Speaker, context: String) async throws -> [String] {
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["claims"],
            "properties": ["claims": ["type": "array", "items": ["type": "string"]]]
        ]
        let reply = try await OpenAI.respond(model: model, instructions: """
            You read a live call transcript (speech-to-text, so expect small errors). From NEW, extract claims the speaker \
            states as fact that can be checked on the web: numbers, dates, records, rankings, science, history, public \
            companies, public people, products and events. Skip opinions, predictions, jokes, questions, plans, and \
            private facts about the people on the call. Make each claim a short self-contained sentence, resolving pronouns from CONTEXT. \
            Only include claims completed in NEW, not ones already made in CONTEXT. Return at most 2. Usually return none.
            """, input: "CONTEXT:\n\(context.isEmpty ? "(start of call)" : context)\n\nNEW (\(speaker.rawValue)): \(text)", schema: schema)
        struct Claims: Decodable { var claims: [String] }
        return Array((parse(reply.text, as: Claims.self)?.claims ?? []).filter { !$0.isEmpty }.prefix(2))
    }

    /// Prosecutor and defender run in parallel and never see each other's answer.
    /// `said` is the speaker's actual words, so neither judge has to trust the extractor's paraphrase.
    static func judge(_ claim: String, said: String) async throws -> (Verdict, Defense?) {
        async let defense = defend(claim, said: said)
        let verdict = try await prosecute(claim, said: said)
        guard verdict.flagged else { return (verdict, nil) }   // leaving scope cancels the defender
        return (verdict, try await defense)
    }

    static func prosecute(_ claim: String, said: String) async throws -> Verdict {
        let evidence = try await Parallel.search(objective: "Find evidence that this claim is false or misleading: \(claim)", queries: [claim])
        let reply = try await OpenAI.respond(model: judgeModel, instructions: """
            You are a live fact-checker on a call. Using only the EVIDENCE (live web search results), judge the CLAIM. Speech is casual: rounding, \
            approximate numbers and loose wording count as true when the gist is right. "false" = the core is wrong. \
            "misleading" = technically defensible but leaves a clearly false impression. "unverifiable" = not enough evidence, \
            or SAID doesn't actually assert the CLAIM (a question, sarcasm, quoting or disputing someone else). \
            Reply with only a JSON object: {"verdict": "true|false|misleading|unverifiable", "confidence": 0.0-1.0, \
            "correction": "<= 18 words saying what is actually true", "source": "URL from EVIDENCE"}
            """, input: "SAID: \(said)\nCLAIM: \(claim)\n\nEVIDENCE:\n\(Parallel.format(evidence))")
        guard var v = parse(reply.text, as: Verdict.self) else { throw BSError("Fact-checker gave no verdict.") }
        if v.source?.isEmpty ?? true { v.source = evidence.first?.url }
        return v
    }

    static func defend(_ claim: String, said: String) async throws -> Defense {
        let evidence = try await Parallel.search(objective: "Find evidence that this claim is true or roughly right: \(claim)", queries: [claim])
        let reply = try await OpenAI.respond(model: judgeModel, instructions: """
            You are the speaker's defense attorney on a live call. Using only the EVIDENCE (live web search results), make \
            the strongest case that the CLAIM is true or a fair approximation in casual speech (rounding, a reasonable reading, recent changes). Be honest: if \
            the evidence clearly contradicts it, concede. If SAID doesn't actually assert the CLAIM (a question, sarcasm, \
            quoting or disputing someone else), it is defensible. Reply with only a JSON object: {"defensible": true|false, \
            "confidence": 0.0-1.0, "reason": "<= 18 words", "source": "URL from EVIDENCE"}
            """, input: "SAID: \(said)\nCLAIM: \(claim)\n\nEVIDENCE:\n\(Parallel.format(evidence))")
        guard var d = parse(reply.text, as: Defense.self) else { throw BSError("Defense gave no answer.") }
        if d.source?.isEmpty ?? true { d.source = evidence.first?.url }
        return d
    }

    /// Models wrap JSON in prose or code fences; take the outermost object.
    static func parse<T: Decodable>(_ text: String, as: T.Type) -> T? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text[a...b].utf8))
    }
}

// MARK: - OpenAI Responses API

enum OpenAI {
    static var key: String? { Keychain.cached("openai", env: "OPENAI_API_KEY") }

    struct Reply: Decodable {
        struct Item: Decodable { var type: String; var content: [Part]? }
        struct Part: Decodable { var text: String? }
        var output: [Item]
        var text: String { output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }.compactMap(\.text).joined() }
    }

    static func respond(model: String, instructions: String, input: String, schema: [String: Any]? = nil) async throws -> Reply {
        guard let key else { throw BSError("Set your OpenAI key from the 💩 menu.") }
        var body: [String: Any] = ["model": model, "store": false, "instructions": instructions, "input": input]
        if let schema { body["text"] = ["format": ["type": "json_schema", "name": "out", "strict": true, "schema": schema]] }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"; req.timeoutInterval = 45
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
            throw BSError(status == 401 ? "OpenAI key rejected." : status == 429 ? "OpenAI rate limit." : "OpenAI error \(status) \(detail)")
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}

/// Keys live in the login Keychain under service "dev.meercat".
enum Keychain {
    private static func base(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.meercat", kSecAttrAccount as String: account] }
    static func read(_ account: String = "openai") -> String? {
        var out: AnyObject?
        guard SecItemCopyMatching(base(account).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Env first, then Keychain, read once per launch: every Keychain read of another app's item can prompt.
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()
    static func cached(_ account: String, env: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[account] { return hit }
        let v = read(account); cache[account] = v; return v
    }
    static func save(_ value: String, _ account: String = "openai") {
        lock.lock(); cache[account] = value; lock.unlock()
        SecItemDelete(base(account) as CFDictionary)
        SecItemAdd(base(account).merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil)
    }
}

// MARK: - Parallel Search API (docs.parallel.ai/search/search-quickstart)

enum Parallel {
    struct Result: Decodable { var url: String; var title: String?; var publish_date: String?; var excerpts: [String] }
    static let mode = ProcessInfo.processInfo.environment["BS_SEARCH_MODE"] ?? "fast"   // turbo ~0.2s · fast ~0.7s · advanced ~3s
    static var key: String? { Keychain.cached("parallel", env: "PARALLEL_API_KEY") }

    static func search(objective: String, queries: [String]) async throws -> [Result] {
        guard let key else { throw BSError("Set your Parallel key from the 💩 menu.") }
        var req = URLRequest(url: URL(string: "https://api.parallel.ai/v1/search")!)
        req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "objective": objective, "search_queries": queries, "mode": mode,
            "advanced_settings": ["max_results": 5, "excerpt_settings": ["max_chars_per_result": 1500]]
        ] as [String: Any])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BSError(status == 401 || status == 403 ? "Parallel key rejected." : status == 429 ? "Parallel rate limit." : "Parallel error \(status).")
        }
        struct Reply: Decodable { var results: [Result] }
        return try JSONDecoder().decode(Reply.self, from: data).results
    }

    /// Search results as plain text for the judge. Untrusted web text: the judges only weigh it, never obey it.
    static func format(_ results: [Result]) -> String {
        results.isEmpty ? "(no results)" : results.enumerated().map { i, r in
            "[\(i + 1)] \(r.title ?? "") (\(r.url))\(r.publish_date.map { ", \($0)" } ?? "")\n\(r.excerpts.joined(separator: "\n"))"
        }.joined(separator: "\n\n")
    }
}
