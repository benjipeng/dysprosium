import Foundation

/// Pure, thread-safe (`nonisolated`) compiler translating MV3 Declarative Net Request JSON
/// and Adblock Plus / AdGuard / EasyList filter syntax into WebKit C++ DFA rule dictionaries.
/// Decoupled from `@MainActor` so 50k–150k+ community filter rules parse off the UI thread with zero hitch.
public enum WebKitRuleCompiler {
    public static let maxCompiledScriptletRules = 12_000

    public struct CompiledScriptletRule: Codable, Equatable, Hashable, Sendable {
        public let positiveDomains: [String]
        public let excludedDomains: [String]
        public let primitive: String
        public let args: [String]

        public init(
            positiveDomains: [String],
            excludedDomains: [String],
            primitive: String,
            args: [String]
        ) {
            self.positiveDomains = positiveDomains
            self.excludedDomains = excludedDomains
            self.primitive = primitive
            self.args = args
        }
    }

    public struct ScriptletExceptionRule: Equatable, Hashable, Sendable {
        public let domains: [String]
        public let primitive: String?
        public let args: [String]

        public init(domains: [String], primitive: String?, args: [String]) {
            self.domains = domains
            self.primitive = primitive
            self.args = args
        }
    }

    public struct CompiledRuleBuckets {
        public var blockAndCosmeticRules: [[String: Any]] = []
        public var allowRules: [[String: Any]] = []
        public var scriptletRules: [CompiledScriptletRule] = []
        public var scriptletExceptions: [ScriptletExceptionRule] = []

        public init(
            blockAndCosmeticRules: [[String: Any]] = [],
            allowRules: [[String: Any]] = [],
            scriptletRules: [CompiledScriptletRule] = [],
            scriptletExceptions: [ScriptletExceptionRule] = []
        ) {
            self.blockAndCosmeticRules = blockAndCosmeticRules
            self.allowRules = allowRules
            self.scriptletRules = scriptletRules
            self.scriptletExceptions = scriptletExceptions
        }

        public var totalCount: Int {
            blockAndCosmeticRules.count + allowRules.count + scriptletRules.count
        }
    }

    // MARK: - 1. MV3 Declarative Net Request JSON Translator

    public static func parseDNRJSONToBuckets(_ jsonData: Data, maxRules: Int = 14_000) -> CompiledRuleBuckets {
        guard let rawArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            return CompiledRuleBuckets()
        }

        var buckets = CompiledRuleBuckets()

        for item in rawArray {
            if buckets.totalCount >= maxRules { break }
            guard let action = item["action"] as? [String: Any],
                  let actionType = action["type"] as? String,
                  (actionType == "block" || actionType == "allow" || actionType == "allowAllRequests"),
                  let condition = item["condition"] as? [String: Any] else {
                continue
            }

            let initDomains = condition["initiatorDomains"] as? [String]
            let exclDomains = condition["excludedInitiatorDomains"] as? [String]
            if let initDomains, initDomains.count > 120 { continue }
            if let exclDomains, exclDomains.count > 120 { continue }

            let isBlock = (actionType == "block")
            let isAllow = !isBlock
            var candidatePatterns: [String] = []
            if let urlFilter = condition["urlFilter"] as? String {
                if let dfa = convertDNRURLFilterToWebKitDFA(urlFilter, isAllow: isAllow) {
                    candidatePatterns.append(dfa)
                }
            } else if let reqDomains = condition["requestDomains"] as? [String],
                      !reqDomains.isEmpty,
                      (reqDomains.count <= 25 || (initDomains?.count ?? 0) <= 40),
                      reqDomains.count <= 2_000 {
                for dom in reqDomains {
                    if let dfa = convertDomainToWebKitDFA(dom) {
                        candidatePatterns.append(dfa)
                    }
                }
            }

            guard !candidatePatterns.isEmpty else { continue }

            var baseTrigger: [String: Any] = [:]
            if let isCase = condition["isUrlFilterCaseSensitive"] as? Bool, isCase {
                baseTrigger["url-filter-is-case-sensitive"] = true
            }
            if let domainType = condition["domainType"] as? String {
                if domainType == "thirdParty" {
                    baseTrigger["load-type"] = ["third-party"]
                } else if domainType == "firstParty" {
                    baseTrigger["load-type"] = ["first-party"]
                }
            }
            if let resTypes = condition["resourceTypes"] as? [String] {
                let mapped = mapDNRResourceTypes(resTypes)
                if !mapped.isEmpty {
                    baseTrigger["resource-type"] = mapped
                }
            }

            if let initDomains, !initDomains.isEmpty {
                let ascii = initDomains.compactMap(sanitizeDomainWildcard)
                guard !ascii.isEmpty else { continue }
                baseTrigger["if-domain"] = ascii
            } else if let exclDomains, !exclDomains.isEmpty {
                let ascii = exclDomains.compactMap(sanitizeDomainWildcard)
                guard !ascii.isEmpty else { continue }
                baseTrigger["unless-domain"] = ascii
            }

            let wkAction: [String: Any] = ["type": isBlock ? "block" : "ignore-previous-rules"]

            for pattern in candidatePatterns {
                if buckets.totalCount >= maxRules { break }
                var trigger = baseTrigger
                trigger["url-filter"] = pattern
                let rule: [String: Any] = ["trigger": trigger, "action": wkAction]
                if isBlock {
                    buckets.blockAndCosmeticRules.append(rule)
                } else {
                    buckets.allowRules.append(rule)
                }
            }
        }

        return buckets
    }

    // MARK: - 2. Adblock Plus / AdGuard iOS / EasyList Syntax Compiler

    public static func parseABPFilterTextToBuckets(_ text: String, maxRules: Int = 24_000) -> CompiledRuleBuckets {
        var buckets = CompiledRuleBuckets()
        var globalCosmeticSelectors: [String] = []
        var excludedGlobalSelectors: Set<String> = []
        var seenGlobalSelectors: Set<String> = []
        var domainCosmeticOrder: [String] = []
        var domainCosmeticTriggers: [String: [String: Any]] = [:]
        var domainCosmeticSelectors: [String: [String]] = [:]
        var domainCosmeticSeen: [String: Set<String>] = [:]
        var rawScriptletRules: [CompiledScriptletRule] = []
        var scriptletExceptions: [ScriptletExceptionRule] = []

        var lineCursor = text.startIndex
        while lineCursor < text.endIndex {
            if (buckets.blockAndCosmeticRules.count + buckets.allowRules.count) >= maxRules {
                break
            }
            let lineEnd = text[lineCursor...].firstIndex(where: \.isNewline) ?? text.endIndex
            let rawLine = text[lineCursor..<lineEnd]
            lineCursor = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            if rawLine.isEmpty { continue }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") {
                continue
            }

            if let scriptletExc = parseScriptletExceptionLine(line) {
                scriptletExceptions.append(scriptletExc)
                continue
            }

            if let excRange = line.range(of: "#@#") {
                let prefix = line[..<excRange.lowerBound]
                let sel = String(line[excRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if prefix.isEmpty, !sel.isEmpty, !sel.hasPrefix("+js(") {
                    excludedGlobalSelectors.insert(sel)
                }
                continue
            }

            if line.contains("##+js(") || line.contains("#%#") {
                if rawScriptletRules.count < Self.maxCompiledScriptletRules,
                   let compiledScriptlet = parseScriptletInjectionLine(line) {
                    rawScriptletRules.append(compiledScriptlet)
                }
                continue
            }

            if line.contains("#?#")
                || line.contains("#$#")
                || line.contains("#@%#")
                || line.contains("##^") {
                continue
            }

            if let cosmeticRange = line.range(of: "##") {
                let domainPart = String(line[..<cosmeticRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let selector = String(line[cosmeticRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                guard isValidWebKitCSSSelector(selector) else { continue }

                if domainPart.isEmpty {
                    // Reject unscoped global `:has(...)` selectors so WebKit never evaluates relational
                    // pseudo-classes across every DOM node on every page; domain-scoped `:has(...)` stays enabled.
                    guard !selector.lowercased().contains(":has(") else { continue }
                    if seenGlobalSelectors.insert(selector).inserted {
                        globalCosmeticSelectors.append(selector)
                    }
                } else {
                    let tokens = domainPart.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard !tokens.isEmpty, tokens.count <= 40, tokens.allSatisfy({ !$0.hasSuffix(".*") }) else {
                        continue
                    }
                    let allNegated = tokens.allSatisfy { $0.hasPrefix("~") }
                    let allPositive = tokens.allSatisfy { !$0.hasPrefix("~") }
                    guard allPositive || allNegated else { continue }

                    if allPositive {
                        let domains = tokens.compactMap(sanitizeDomainWildcard)
                        guard domains.count == tokens.count else { continue }
                        let sortedDomains = domains.sorted()
                        let groupKey = "if:" + sortedDomains.joined(separator: ",")
                        if domainCosmeticTriggers[groupKey] == nil {
                            domainCosmeticOrder.append(groupKey)
                            domainCosmeticTriggers[groupKey] = [
                                "url-filter": "^https?://",
                                "if-domain": sortedDomains
                            ]
                        }
                        if domainCosmeticSeen[groupKey, default: []].insert(selector).inserted {
                            domainCosmeticSelectors[groupKey, default: []].append(selector)
                        }
                    } else {
                        let domains = tokens.compactMap { sanitizeDomainWildcard(String($0.dropFirst())) }
                        guard domains.count == tokens.count else { continue }
                        let sortedDomains = domains.sorted()
                        let groupKey = "unless:" + sortedDomains.joined(separator: ",")
                        if domainCosmeticTriggers[groupKey] == nil {
                            domainCosmeticOrder.append(groupKey)
                            domainCosmeticTriggers[groupKey] = [
                                "url-filter": "^https?://",
                                "unless-domain": sortedDomains
                            ]
                        }
                        if domainCosmeticSeen[groupKey, default: []].insert(selector).inserted {
                            domainCosmeticSelectors[groupKey, default: []].append(selector)
                        }
                    }
                }
                continue
            }

            var working = line
            var isAllow = false
            if working.hasPrefix("@@") {
                isAllow = true
                working.removeFirst(2)
            }

            var patternPart = working
            var optionsPart: String?
            if let dollarIdx = findOptionDollarDelimiter(in: working) {
                patternPart = String(working[..<dollarIdx])
                optionsPart = String(working[working.index(after: dollarIdx)...])
            }

            if patternPart.hasPrefix("/") && patternPart.hasSuffix("/") && patternPart.count > 2 {
                continue
            }

            var trigger: [String: Any] = [:]
            if let opts = optionsPart {
                guard applyABPOptions(opts, isAllow: isAllow, into: &trigger) else {
                    continue
                }
            }

            let dfaPattern: String?
            if (patternPart.isEmpty || patternPart == "*"), trigger["resource-type"] != nil || trigger["if-domain"] != nil {
                dfaPattern = "^https?://"
            } else {
                dfaPattern = convertDNRURLFilterToWebKitDFA(patternPart, isAllow: isAllow)
            }

            guard let validDFA = dfaPattern else { continue }
            trigger["url-filter"] = validDFA

            let rule: [String: Any] = [
                "trigger": trigger,
                "action": ["type": isAllow ? "ignore-previous-rules" : "block"]
            ]

            if isAllow {
                buckets.allowRules.append(rule)
            } else {
                buckets.blockAndCosmeticRules.append(rule)
            }
        }

        for groupKey in domainCosmeticOrder {
            guard (buckets.blockAndCosmeticRules.count + buckets.allowRules.count) < maxRules,
                  let trigger = domainCosmeticTriggers[groupKey],
                  let selectors = domainCosmeticSelectors[groupKey],
                  !selectors.isEmpty else {
                continue
            }
            var batch: [String] = []
            var charCount = 0
            for sel in selectors {
                let addedLen = batch.isEmpty ? sel.count : (sel.count + 2)
                if !batch.isEmpty && (batch.count >= 16 || charCount + addedLen > 900) {
                    if (buckets.blockAndCosmeticRules.count + buckets.allowRules.count) >= maxRules { break }
                    buckets.blockAndCosmeticRules.append([
                        "trigger": trigger,
                        "action": [
                            "type": "css-display-none",
                            "selector": batch.joined(separator: ", ")
                        ]
                    ])
                    batch.removeAll(keepingCapacity: true)
                    charCount = 0
                }
                batch.append(sel)
                charCount += batch.count == 1 ? sel.count : (sel.count + 2)
            }
            if !batch.isEmpty && (buckets.blockAndCosmeticRules.count + buckets.allowRules.count) < maxRules {
                buckets.blockAndCosmeticRules.append([
                    "trigger": trigger,
                    "action": [
                        "type": "css-display-none",
                        "selector": batch.joined(separator: ", ")
                    ]
                ])
            }
        }

        if !excludedGlobalSelectors.isEmpty {
            globalCosmeticSelectors.removeAll { excludedGlobalSelectors.contains($0) }
        }

        let batchSize = 20
        var idx = 0
        while idx < globalCosmeticSelectors.count && (buckets.blockAndCosmeticRules.count + buckets.allowRules.count) < maxRules {
            let end = min(idx + batchSize, globalCosmeticSelectors.count)
            let joined = globalCosmeticSelectors[idx..<end].joined(separator: ", ")
            buckets.blockAndCosmeticRules.append([
                "trigger": ["url-filter": "^https?://"],
                "action": [
                    "type": "css-display-none",
                    "selector": joined
                ]
            ])
            idx = end
        }

        buckets.scriptletRules = resolveScriptletRules(
            rawScriptletRules,
            exceptions: scriptletExceptions,
            maxRules: Self.maxCompiledScriptletRules
        )
        buckets.scriptletExceptions = scriptletExceptions

        return buckets
    }

    // MARK: - 3. uBlock Origin & AdGuard Scriptlet Compiler

    public static func canonicalizeScriptletPrimitive(_ rawName: String) -> String? {
        var cleaned = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        if cleaned.hasSuffix(".js") {
            cleaned.removeLast(3)
        }
        if cleaned.hasPrefix("ubo-") {
            cleaned.removeFirst(4)
        } else if cleaned.hasPrefix("abp-") {
            cleaned.removeFirst(4)
        } else if cleaned.hasPrefix("adg-") {
            cleaned.removeFirst(4)
        }
        if cleaned.hasSuffix(".js") {
            cleaned.removeLast(3)
        }

        switch cleaned {
        case "set-constant", "set":
            return "set-constant"
        case "abort-on-property-read", "aopr":
            return "abort-on-property-read"
        case "abort-on-property-write", "aopw":
            return "abort-on-property-write"
        case "abort-current-inline-script", "acis", "acs", "abort-current-script":
            return "abort-current-inline-script"
        case "abort-on-stack-trace", "aost":
            return "abort-on-stack-trace"
        case "addeventlistener-defuser", "aeld", "prevent-addeventlistener":
            return "addEventListener-defuser"
        case "no-settimeout-if", "nostif", "settimeout-defuser", "prevent-settimeout":
            return "no-setTimeout-if"
        case "no-setinterval-if", "nosiif", "setinterval-defuser", "prevent-setinterval":
            return "no-setInterval-if"
        case "adjust-settimeout", "nano-stb", "nano-settimeout-booster":
            return "adjust-setTimeout"
        case "adjust-setinterval", "nano-sib", "nano-setinterval-booster":
            return "adjust-setInterval"
        case "no-window-open-if", "nowoif", "prevent-window-open", "window.open-defuser":
            return "no-window-open-if"
        case "no-fetch-if", "prevent-fetch":
            return "no-fetch-if"
        case "no-xhr-if", "prevent-xhr":
            return "no-xhr-if"
        case "json-prune":
            return "json-prune"
        case "json-prune-fetch-response":
            return "json-prune-fetch-response"
        case "json-prune-xhr-response":
            return "json-prune-xhr-response"
        case "remove-attr", "ra":
            return "remove-attr"
        case "remove-class", "rc":
            return "remove-class"
        case "remove-node-text", "rmnt":
            return "remove-node-text"
        case "set-local-storage-item":
            return "set-local-storage-item"
        case "trusted-set-local-storage-item":
            return "trusted-set-local-storage-item"
        case "set-session-storage-item":
            return "set-session-storage-item"
        case "trusted-set-session-storage-item":
            return "trusted-set-session-storage-item"
        case "set-cookie":
            return "set-cookie"
        case "set-cookie-reload":
            return "set-cookie-reload"
        case "trusted-set-cookie":
            return "trusted-set-cookie"
        case "remove-cookie", "cookie-remover":
            return "remove-cookie"
        case "href-sanitizer":
            return "href-sanitizer"
        case "prevent-element-src-loading":
            return "prevent-element-src-loading"
        case "noeval-if", "prevent-eval-if":
            return "noeval-if"
        default:
            return nil
        }
    }

    public static func resolveScriptletRules(
        _ rules: [CompiledScriptletRule],
        exceptions: [ScriptletExceptionRule],
        maxRules: Int = maxCompiledScriptletRules
    ) -> [CompiledScriptletRule] {
        guard maxRules > 0, !rules.isEmpty else { return [] }
        var resolved: [CompiledScriptletRule] = []
        resolved.reserveCapacity(min(rules.count, maxRules))
        var seen = Set<CompiledScriptletRule>()

        var wildcardExceptions: [ScriptletExceptionRule] = []
        var exceptionsByPrimitive: [String: [ScriptletExceptionRule]] = [:]
        for exc in exceptions {
            if let prim = exc.primitive {
                exceptionsByPrimitive[prim, default: []].append(exc)
            } else {
                wildcardExceptions.append(exc)
            }
        }

        for rule in rules {
            if resolved.count >= maxRules { break }
            var posDomains = rule.positiveDomains
            var exclDomains = rule.excludedDomains
            var cancelledAll = false

            let relevantExceptions: [ScriptletExceptionRule]
            if let primBucket = exceptionsByPrimitive[rule.primitive] {
                relevantExceptions = wildcardExceptions.isEmpty ? primBucket : (wildcardExceptions + primBucket)
            } else {
                relevantExceptions = wildcardExceptions
            }

            for exc in relevantExceptions {
                if exc.primitive != nil && !exc.args.isEmpty && exc.args != rule.args {
                    continue
                }

                if exc.domains.isEmpty {
                    cancelledAll = true
                    break
                }

                for excDom in exc.domains {
                    posDomains.removeAll { pos in
                        pos == excDom || pos.hasSuffix(".\(excDom)")
                    }
                    let narrowsRemainingPositive = posDomains.contains { pos in
                        excDom.hasSuffix(".\(pos)")
                    }
                    if narrowsRemainingPositive && !exclDomains.contains(excDom) {
                        exclDomains.append(excDom)
                    }
                }

                if posDomains.isEmpty {
                    cancelledAll = true
                    break
                }
            }

            guard !cancelledAll, !posDomains.isEmpty else { continue }
            let finalRule = CompiledScriptletRule(
                positiveDomains: posDomains,
                excludedDomains: exclDomains,
                primitive: rule.primitive,
                args: rule.args
            )
            if seen.insert(finalRule).inserted {
                resolved.append(finalRule)
            }
        }

        return resolved
    }

    private static func parseScriptletInjectionLine(_ line: String) -> CompiledScriptletRule? {
        if let uboRange = line.range(of: "##+js("), line.hasSuffix(")") {
            let domainPart = String(line[..<uboRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let bodyEnd = line.index(before: line.endIndex)
            guard uboRange.upperBound <= bodyEnd else { return nil }
            let body = String(line[uboRange.upperBound..<bodyEnd])
            return buildCompiledScriptletRule(domainPart: domainPart, rawCallBody: body)
        }

        if let agRange = line.range(of: "#%#") {
            let domainPart = String(line[..<agRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[agRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let prefix = "//scriptlet("
            guard rhs.hasPrefix(prefix), rhs.hasSuffix(")") else { return nil }
            let bodyStart = rhs.index(rhs.startIndex, offsetBy: prefix.count)
            let bodyEnd = rhs.index(before: rhs.endIndex)
            guard bodyStart <= bodyEnd else { return nil }
            let body = String(rhs[bodyStart..<bodyEnd])
            return buildCompiledScriptletRule(domainPart: domainPart, rawCallBody: body)
        }

        return nil
    }

    private static func parseScriptletExceptionLine(_ line: String) -> ScriptletExceptionRule? {
        let domainPart: String
        let body: String

        if let uboExc = line.range(of: "#@#+js("), line.hasSuffix(")") {
            domainPart = String(line[..<uboExc.lowerBound]).trimmingCharacters(in: .whitespaces)
            let bodyEnd = line.index(before: line.endIndex)
            guard uboExc.upperBound <= bodyEnd else { return nil }
            body = String(line[uboExc.upperBound..<bodyEnd])
        } else if let agExc = line.range(of: "#@%#") {
            domainPart = String(line[..<agExc.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[agExc.upperBound...]).trimmingCharacters(in: .whitespaces)
            let prefix = "//scriptlet("
            guard rhs.hasPrefix(prefix), rhs.hasSuffix(")") else { return nil }
            let bodyStart = rhs.index(rhs.startIndex, offsetBy: prefix.count)
            let bodyEnd = rhs.index(before: rhs.endIndex)
            guard bodyStart <= bodyEnd else { return nil }
            body = String(rhs[bodyStart..<bodyEnd])
        } else {
            return nil
        }

        let excDomains: [String]
        if domainPart.isEmpty || domainPart == "*" {
            excDomains = []
        } else {
            let (positive, _) = parseScriptletDomains(domainPart)
            guard !positive.isEmpty else { return nil }
            excDomains = positive
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.isEmpty {
            return ScriptletExceptionRule(domains: excDomains, primitive: nil, args: [])
        }

        let tokens = splitScriptletArguments(body)
        guard let rawName = tokens.first,
              let canonical = canonicalizeScriptletPrimitive(rawName) else {
            return nil
        }
        return ScriptletExceptionRule(
            domains: excDomains,
            primitive: canonical,
            args: Array(tokens.dropFirst())
        )
    }

    private static func buildCompiledScriptletRule(domainPart: String, rawCallBody: String) -> CompiledScriptletRule? {
        guard !domainPart.isEmpty, domainPart != "*" else { return nil }
        let (positiveDomains, excludedDomains) = parseScriptletDomains(domainPart)
        guard !positiveDomains.isEmpty else { return nil }

        let tokens = splitScriptletArguments(rawCallBody)
        guard let rawName = tokens.first,
              let canonical = canonicalizeScriptletPrimitive(rawName) else {
            return nil
        }

        return CompiledScriptletRule(
            positiveDomains: positiveDomains,
            excludedDomains: excludedDomains,
            primitive: canonical,
            args: Array(tokens.dropFirst())
        )
    }

    private static func parseScriptletDomains(_ domainPart: String) -> (positive: [String], excluded: [String]) {
        let rawTokens = domainPart.split(separator: ",", omittingEmptySubsequences: true)
        guard !rawTokens.isEmpty, rawTokens.count <= 500 else { return ([], []) }

        var positive: [String] = []
        var excluded: [String] = []
        var seenPositive = Set<String>()
        var seenExcluded = Set<String>()

        for raw in rawTokens {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("~") {
                let candidate = String(trimmed.dropFirst())
                if let clean = sanitizeConcreteScriptletDomain(candidate), seenExcluded.insert(clean).inserted {
                    excluded.append(clean)
                }
            } else {
                if let clean = sanitizeConcreteScriptletDomain(trimmed), seenPositive.insert(clean).inserted {
                    positive.append(clean)
                }
            }
        }

        if !excluded.isEmpty {
            positive.removeAll { seenExcluded.contains($0) }
        }
        return (positive, excluded)
    }

    private static func sanitizeConcreteScriptletDomain(_ domain: String) -> String? {
        let clean = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !clean.isEmpty,
              clean != "*",
              !clean.contains("*"),
              clean.contains("."),
              !clean.contains(".."),
              clean.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E }) else {
            return nil
        }
        return clean
    }

    public static func splitScriptletArguments(_ raw: String) -> [String] {
        let trimmedOuter = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOuter.isEmpty else { return [] }

        let chars = Array(trimmedOuter)
        var results: [String] = []
        var current = ""
        var activeQuote: Character?
        var tokenStarted = false
        var tokenWasQuoted = false
        var afterClosingQuote = false
        var idx = 0

        while idx < chars.count {
            let ch = chars[idx]

            if let quote = activeQuote {
                if ch == "\\", idx + 1 < chars.count {
                    let next = chars[idx + 1]
                    if next == quote || next == "\\" || next == "," {
                        current.append(next)
                    } else if next == "n" {
                        current.append("\n")
                    } else if next == "t" {
                        current.append("\t")
                    } else {
                        current.append("\\")
                        current.append(next)
                    }
                    idx += 2
                    continue
                }
                if ch == quote {
                    activeQuote = nil
                    afterClosingQuote = true
                    idx += 1
                    continue
                }
                current.append(ch)
                idx += 1
                continue
            }

            if !tokenStarted {
                if ch.isWhitespace {
                    idx += 1
                    continue
                }
                if ch == "'" || ch == "\"" {
                    tokenStarted = true
                    tokenWasQuoted = true
                    activeQuote = ch
                    idx += 1
                    continue
                }
                if ch == "," {
                    results.append("")
                    idx += 1
                    continue
                }
                tokenStarted = true
            }

            if ch == "," {
                let finalized = tokenWasQuoted ? current : current.trimmingCharacters(in: .whitespaces)
                results.append(finalized)
                current = ""
                tokenStarted = false
                tokenWasQuoted = false
                afterClosingQuote = false
                idx += 1
                continue
            }

            if afterClosingQuote {
                idx += 1
                continue
            }

            if ch == "\\", idx + 1 < chars.count {
                let next = chars[idx + 1]
                if next == "," {
                    current.append(",")
                    idx += 2
                    continue
                }
                current.append("\\")
                current.append(next)
                idx += 2
                continue
            }

            current.append(ch)
            idx += 1
        }

        let finalized = tokenWasQuoted ? current : current.trimmingCharacters(in: .whitespaces)
        results.append(finalized)
        return results
    }

    // MARK: - Option, Selector & O(N) Prefix-Trie DFA Helpers

    private static let unsupportedABPOptions: Set<String> = [
        "badfilter", "csp", "removeparam", "redirect", "redirect-rule", "rewrite",
        "replace", "hls", "jsonprune", "generichide", "elemhide", "specifichide",
        "header", "permissions", "webrtc", "denyallow", "to", "method"
    ]

    private static func applyABPOptions(_ rawOptions: String, isAllow: Bool, into trigger: inout [String: Any]) -> Bool {
        var resourceTypes: Set<String> = []
        var excludedResourceTypes: Set<String> = []
        var loadType: String?
        var positiveDomains: [String] = []
        var negativeDomains: [String] = []

        for rawToken in rawOptions.split(separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            let lower = token.lowercased()
            if lower.isEmpty { continue }

            let keyName = lower.split(separator: "=").first.map(String.init) ?? lower
            if unsupportedABPOptions.contains(keyName) {
                return false
            }

            if lower.hasPrefix("domain=") {
                let domList = token.dropFirst("domain=".count)
                let items = domList.split(separator: "|")
                guard !items.isEmpty, items.count <= 80 else { return false }
                for item in items {
                    if item.hasPrefix("~") {
                        let clean = String(item.dropFirst())
                        guard let w = sanitizeDomainWildcard(clean) else { return false }
                        negativeDomains.append(w)
                    } else {
                        let clean = String(item)
                        guard let w = sanitizeDomainWildcard(clean) else { return false }
                        positiveDomains.append(w)
                    }
                }
                continue
            }

            switch lower {
            case "third-party", "3p":
                loadType = "third-party"
            case "~third-party", "first-party", "1p", "~3p":
                loadType = "first-party"
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "important", "all":
                break
            case "script":
                resourceTypes.insert("script")
            case "~script":
                excludedResourceTypes.insert("script")
            case "image":
                resourceTypes.insert("image")
            case "~image":
                excludedResourceTypes.insert("image")
            case "stylesheet", "css":
                resourceTypes.insert("style-sheet")
            case "~stylesheet", "~css":
                excludedResourceTypes.insert("style-sheet")
            case "xmlhttprequest", "xhr", "ping", "other", "websocket", "beacon":
                resourceTypes.insert("raw")
            case "~xmlhttprequest", "~xhr", "~ping", "~other", "~websocket", "~beacon":
                excludedResourceTypes.insert("raw")
            case "media":
                resourceTypes.insert("media")
            case "~media":
                excludedResourceTypes.insert("media")
            case "font":
                resourceTypes.insert("font")
            case "~font":
                excludedResourceTypes.insert("font")
            case "subdocument", "subdoc", "frame", "document", "doc":
                resourceTypes.insert("document")
            case "~subdocument", "~subdoc", "~frame", "~document", "~doc":
                excludedResourceTypes.insert("document")
            case "popup":
                resourceTypes.insert("popup")
            case "~popup":
                excludedResourceTypes.insert("popup")
            default:
                if !isAllow { return false }
            }
        }

        if !positiveDomains.isEmpty && !negativeDomains.isEmpty {
            return false
        }
        if !positiveDomains.isEmpty {
            trigger["if-domain"] = positiveDomains
        } else if !negativeDomains.isEmpty {
            trigger["unless-domain"] = negativeDomains
        }

        if let loadType {
            trigger["load-type"] = [loadType]
        }

        if !resourceTypes.isEmpty {
            trigger["resource-type"] = Array(resourceTypes)
        } else if !excludedResourceTypes.isEmpty {
            let allWebKitTypes: Set<String> = ["document", "image", "style-sheet", "script", "font", "raw", "media", "popup"]
            let remaining = allWebKitTypes.subtracting(excludedResourceTypes)
            if !remaining.isEmpty {
                trigger["resource-type"] = Array(remaining)
            }
        }

        return true
    }

    private static func findOptionDollarDelimiter(in rule: String) -> String.Index? {
        guard let idx = rule.lastIndex(of: "$") else { return nil }
        let tail = rule[rule.index(after: idx)...]
        if tail.isEmpty { return nil }
        let validStartChars = CharacterSet.letters.union(CharacterSet(charactersIn: "~13"))
        guard let firstScalar = tail.unicodeScalars.first, validStartChars.contains(firstScalar) else {
            return nil
        }
        return idx
    }

    private static func isValidWebKitCSSSelector(_ selector: String) -> Bool {
        guard selector.count >= 2, selector.count <= 320 else { return false }
        guard selector.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return false }

        let lower = selector.lowercased()
        let forbiddenTokens = [
            ":has-text(", ":contains(", ":-abp-", ":xpath(", ":upward(",
            ":matches-css(", ":matches-css-before(", ":matches-css-after(",
            ":matches-attr(", ":matches-property(", ":matches-path(",
            ":min-text-length(", ":nth-ancestor(", ":others(", ":watch-attr(",
            ":remove(", ":remove-attr(", ":remove-class(", ":style(", "{"
        ]
        for bad in forbiddenTokens where lower.contains(bad) {
            return false
        }
        return true
    }

    private static func convertDomainToWebKitDFA(_ domain: String) -> String? {
        let clean = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !clean.isEmpty,
              clean.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E }) else {
            return nil
        }
        let escaped = clean.replacingOccurrences(of: ".", with: "\\.")
        // Apple / AdGuard canonical non-nested subdomain anchor: avoids nested Kleene star `([a-z0-9-]+\.)*`
        // which causes exponential NFA->DFA state explosion (100+ MB bytecode) in WebKit's CombinedURLFilters.
        return "^https?://+([^:/]+\\.)?\(escaped)[/:?#]"
    }

    public static func convertDNRURLFilterToWebKitDFA(_ filter: String, isAllow: Bool = false) -> String? {
        guard !filter.isEmpty, filter.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
            return nil
        }

        var working = filter
        var hasDomainAnchor = false
        var hasStartAnchor = false
        var hasEndAnchor = false

        if working.hasPrefix("||") {
            hasDomainAnchor = true
            working.removeFirst(2)
        } else if working.hasPrefix("|") {
            hasStartAnchor = true
            working.removeFirst()
        }

        if working.hasSuffix("|") {
            hasEndAnchor = true
            working.removeLast()
        }

        while working.hasPrefix("*") { working.removeFirst() }
        while working.hasSuffix("*") { working.removeLast() }

        // Collapse consecutive wildcards (`**` -> `*`) to avoid redundant Kleene loops.
        while working.contains("**") {
            working = working.replacingOccurrences(of: "**", with: "*")
        }

        if !hasDomainAnchor && !hasStartAnchor && working.count < 4 {
            return nil
        }
        guard !working.isEmpty else { return nil }

        // Guard against catastrophic DFA state blowup from multi-wildcard block patterns.
        // Exception (`@@` / `allow`) rules have a separate, generous wildcard budget (<= 1,500 rules total)
        // so legitimate multi-wildcard unbreak exceptions are never silently dropped while their
        // corresponding block rules remain active.
        let wildcardCount = working.reduce(0) { $0 + ($1 == "*" ? 1 : 0) }
        if !isAllow {
            if wildcardCount >= 3 || (!hasDomainAnchor && !hasStartAnchor && wildcardCount >= 2) {
                return nil
            }
        } else if wildcardCount >= 6 {
            return nil
        }

        var out = ""
        if hasDomainAnchor {
            out += "^https?://+([^:/]+\\.)?"
        } else if hasStartAnchor {
            out += "^"
        }

        let isHostOnlyDomainRule = hasDomainAnchor && !working.contains("/") && !working.contains("?")
        let chars = Array(working)
        var emittedTerminalEnd = false
        for (idx, ch) in chars.enumerated() {
            let isLast = (idx == chars.count - 1)
            switch ch {
            case "*":
                out += ".*"
            case "^":
                if isLast && isHostOnlyDomainRule {
                    // Canonicalized HTTP(S) URLs always contain `/` (or `:`, `?`, `#`) after the host.
                    out += "[/:?#]"
                } else if isLast && hasEndAnchor {
                    out += "[/:?#&]?$"
                    emittedTerminalEnd = true
                } else if isLast {
                    // Preserve exact ABP `^` end-of-URL semantics for path/query rules (matching BOTH
                    // `https://host/ad` and `https://host/ad?x=1` without matching `/adverse`).
                    out += "([/:?#&].*)?$"
                    emittedTerminalEnd = true
                } else {
                    out += "[/:?#&]"
                }
            case ".", "+", "?", "$", "(", ")", "[", "]", "{", "}", "|", "\\":
                out.append("\\")
                out.append(ch)
            default:
                out.append(ch)
            }
        }

        if hasEndAnchor && !emittedTerminalEnd {
            out += "$"
        }
        return out
    }

    private static func sanitizeDomainWildcard(_ domain: String) -> String? {
        let clean = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".* "))
        guard clean.contains("."),
              clean.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x2E }) else {
            return nil
        }
        return "*\(clean)"
    }

    private static func mapDNRResourceTypes(_ types: [String]) -> [String] {
        var mapped: Set<String> = []
        for t in types {
            switch t {
            case "script": mapped.insert("script")
            case "image": mapped.insert("image")
            case "stylesheet": mapped.insert("style-sheet")
            case "media": mapped.insert("media")
            case "font": mapped.insert("font")
            case "popup": mapped.insert("popup")
            case "xmlhttprequest", "ping", "other", "websocket": mapped.insert("raw")
            case "sub_frame", "main_frame": mapped.insert("document")
            default: break
            }
        }
        return Array(mapped)
    }
}
