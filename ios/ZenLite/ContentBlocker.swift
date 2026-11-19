import Foundation
import WebKit

/// Compiles the bundled ad/tracker host list into a native WebKit content
/// rule list. WebKit applies it inside the page process, so blocked requests
/// never start and cost no memory.
enum ContentBlocker {
    static func load(completion: @escaping (WKContentRuleList?) -> Void) {
        guard
            let url = Bundle.main.url(forResource: "blocklist", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            completion(nil)
            return
        }
        let hosts = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.contains("/") }

        var rules: [[String: Any]] = []
        for host in hosts {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            // The host itself, and any subdomain of it.
            for pattern in ["^https?://" + escaped + "[:/]", "^https?://[^/]*\\." + escaped + "[:/]"] {
                rules.append([
                    "trigger": ["url-filter": pattern],
                    "action": ["type": "block"],
                ])
            }
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: rules),
            let json = String(data: data, encoding: .utf8)
        else {
            completion(nil)
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "zenlite-blocklist",
            encodedContentRuleList: json
        ) { list, _ in
            completion(list)
        }
    }
}
