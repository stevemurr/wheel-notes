import Foundation
import WheelSupport

public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case daily
    case adhoc
}

public struct NotePageSource: Codable, Equatable, Sendable {
    public let title: String
    public let url: String
    public let capturedAt: Date

    public init(title: String, url: String, capturedAt: Date = Date()) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title
        self.url = url
        self.capturedAt = capturedAt
    }
}

public struct NoteDocument: Codable, Sendable {
    public var root: [String: AnyCodable]

    public init(root: [String: AnyCodable]) {
        self.root = root
    }

    public static var empty: NoteDocument {
        NoteDocument(
            root: [
                "type": AnyCodable("doc"),
                "content": AnyCodable([Self.emptyParagraphNode]),
            ]
        )
    }

    public static func titled(_ title: String) -> NoteDocument {
        let normalizedTitle = Self.normalizeLine(title)
        guard !normalizedTitle.isEmpty else { return .empty }

        return NoteDocument(
            root: [
                "type": AnyCodable("doc"),
                "content": AnyCodable([Self.paragraphNode(text: normalizedTitle)]),
            ]
        )
    }

    public func plainText(maxLength: Int = 180) -> String {
        let text = Self.documentLines(from: Self.normalizedJSON(root))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Self.truncated(text, maxLength: maxLength)
    }

    public func titleLine(maxLength: Int = 120) -> String {
        let line = Self.documentLines(from: Self.normalizedJSON(root)).first ?? ""
        return Self.truncated(line, maxLength: maxLength)
    }

    public func previewText(maxLength: Int = 180) -> String {
        let lines = Self.documentLines(from: Self.normalizedJSON(root))
        let text = Array(lines.dropFirst())
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Self.truncated(text, maxLength: maxLength)
    }

    public var canonicalJSONString: String? {
        let normalized = Self.normalizedJSON(root)
        guard JSONSerialization.isValidJSONObject(normalized),
              let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }

    public func migratedForInlineTitle(_ legacyTitle: String) -> NoteDocument {
        let normalizedTitle = Self.normalizeLine(legacyTitle)
        guard !normalizedTitle.isEmpty, titleLine(maxLength: Int.max).isEmpty else {
            return self
        }

        var updatedRoot = root
        var content = updatedRoot["content"]?.arrayValue ?? []
        content.insert(Self.paragraphNode(text: normalizedTitle), at: 0)
        updatedRoot["content"] = AnyCodable(content)
        return NoteDocument(root: updatedRoot)
    }

    public func insertingPageSource(_ source: NotePageSource) -> NoteDocument {
        var updatedRoot = root
        var content = updatedRoot["content"]?.arrayValue ?? []
        let attrs: [String: Any] = [
            "title": source.title,
            "url": source.url,
            "capturedAt": Self.iso8601.string(from: source.capturedAt),
        ]

        let pageNode: [String: Any] = [
            "type": "pageSource",
            "attrs": attrs,
        ]

        if Self.isEffectivelyEmptyContent(content) {
            content = [pageNode, Self.emptyParagraphNode]
        } else {
            if let last = content.last, !Self.isEmptyParagraphNode(last) {
                content.append(Self.emptyParagraphNode)
            }
            content.append(pageNode)
            content.append(Self.emptyParagraphNode)
        }

        updatedRoot["content"] = AnyCodable(content)
        return NoteDocument(root: updatedRoot)
    }

    private static let emptyParagraphNode: [String: Any] = [
        "type": "paragraph",
        "content": [],
    ]

    private static func paragraphNode(text: String) -> [String: Any] {
        [
            "type": "paragraph",
            "content": [
                [
                    "type": "text",
                    "text": text,
                ],
            ],
        ]
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func documentLines(from value: Any) -> [String] {
        blockTextLines(from: value)
            .flatMap { $0.components(separatedBy: .newlines) }
            .map(normalizeLine)
            .filter { !$0.isEmpty }
    }

    private static func blockTextLines(from value: Any) -> [String] {
        switch value {
        case let wrapped as AnyCodable:
            return blockTextLines(from: wrapped.value)

        case let dictionary as [String: Any]:
            if let type = dictionary["type"] as? String {
                switch type {
                case "doc", "bulletList", "orderedList", "taskList", "listItem", "taskItem", "table":
                    return blockTextLines(from: dictionary["content"] ?? [])
                case "tableRow":
                    return blockTextLines(from: dictionary["content"] ?? [])
                case "paragraph", "heading":
                    let text = inlineText(from: dictionary["content"] ?? [])
                    return text.isEmpty ? [] : [text]
                case "blockquote", "tableCell", "tableHeader":
                    return blockTextLines(from: dictionary["content"] ?? [])
                case "codeBlock":
                    return inlineText(from: dictionary["content"] ?? [])
                        .components(separatedBy: .newlines)
                        .filter { !$0.isEmpty }
                case "pageSource":
                    if let attrs = dictionary["attrs"] as? [String: Any] {
                        let title = attrs["title"] as? String ?? "Source"
                        let url = attrs["url"] as? String ?? ""
                        let text = [title, url].filter { !$0.isEmpty }.joined(separator: " ")
                        return text.isEmpty ? [] : [text]
                    }
                case "linkCard":
                    if let attrs = dictionary["attrs"] as? [String: Any] {
                        let title = normalizeLine(attrs["title"] as? String ?? "")
                        let url = displayLinkSummary(attrs["url"] as? String ?? "")
                        return [title, url].filter { !$0.isEmpty }
                    }
                default:
                    break
                }
            }

            if let content = dictionary["content"] {
                return blockTextLines(from: content)
            }

            return []

        case let array as [Any]:
            return array.flatMap(blockTextLines(from:))

        default:
            return []
        }
    }

    private static func inlineText(from value: Any) -> String {
        switch value {
        case let wrapped as AnyCodable:
            return inlineText(from: wrapped.value)

        case let dictionary as [String: Any]:
            if let type = dictionary["type"] as? String {
                switch type {
                case "text":
                    return dictionary["text"] as? String ?? ""
                case "hardBreak":
                    return "\n"
                case "pageSource":
                    if let attrs = dictionary["attrs"] as? [String: Any] {
                        let title = attrs["title"] as? String ?? "Source"
                        let url = attrs["url"] as? String ?? ""
                        return [title, url].filter { !$0.isEmpty }.joined(separator: " ")
                    }
                case "linkCard":
                    if let attrs = dictionary["attrs"] as? [String: Any] {
                        let title = normalizeLine(attrs["title"] as? String ?? "")
                        let url = displayLinkSummary(attrs["url"] as? String ?? "")
                        return [title, url].filter { !$0.isEmpty }.joined(separator: " ")
                    }
                default:
                    break
                }
            }

            if let content = dictionary["content"] {
                return inlineText(from: content)
            }

            return ""

        case let array as [Any]:
            return array
                .map(inlineText(from:))
                .joined()

        default:
            return ""
        }
    }

    private static func isEffectivelyEmptyContent(_ content: [Any]) -> Bool {
        content.isEmpty || content.allSatisfy(isEmptyParagraphNode)
    }

    private static func isEmptyParagraphNode(_ value: Any) -> Bool {
        let nodeValue = (value as? AnyCodable)?.value ?? value
        guard let dictionary = nodeValue as? [String: Any],
              dictionary["type"] as? String == "paragraph" else {
            return false
        }

        if let wrapped = dictionary["content"] as? AnyCodable {
            return wrapped.arrayValue?.isEmpty ?? false
        }

        if let array = dictionary["content"] as? [Any] {
            return array.isEmpty
        }

        return dictionary["content"] == nil
    }

    private static func normalizedJSON(_ value: Any) -> Any {
        switch value {
        case let wrapped as AnyCodable:
            return normalizedJSON(wrapped.value)

        case let dictionary as NSDictionary:
            var normalized: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                guard let key = key as? String else { continue }
                normalized[key] = normalizedJSON(nestedValue)
            }
            return normalized

        case let array as NSArray:
            return array.map(normalizedJSON)

        default:
            return value
        }
    }

    private static func normalizeLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayLinkSummary(_ text: String, maxLength: Int = 58) -> String {
        let normalized = normalizeLine(text)
        guard !normalized.isEmpty else { return "" }

        guard let components = URLComponents(string: normalized) else {
            return truncated(normalized, maxLength: maxLength)
        }

        let host = (components.host ?? normalized)
            .replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let path = components.percentEncodedPath == "/" ? "" : components.percentEncodedPath
        let decodedPath = path.removingPercentEncoding ?? path
        let suffix = ((components.percentEncodedQuery?.isEmpty == false) || (components.fragment?.isEmpty == false)) ? "…" : ""
        let display = "\(host)\(decodedPath)\(suffix)"

        return truncated(display.isEmpty ? normalized : display, maxLength: maxLength)
    }

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let index = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

public struct NoteRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let kind: NoteKind
    public var title: String
    public let dayIdentifier: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var excerpt: String
    public var document: NoteDocument

    public init(
        id: UUID = UUID(),
        workspaceID: UUID,
        kind: NoteKind,
        title: String,
        dayIdentifier: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        excerpt: String = "",
        document: NoteDocument = .empty
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
        self.dayIdentifier = dayIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.excerpt = excerpt
        self.document = document
    }

    public var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Note" : title
    }

    public var shortUpdatedText: String {
        updatedAt.abbreviatedRelativeTimeString()
    }
}
