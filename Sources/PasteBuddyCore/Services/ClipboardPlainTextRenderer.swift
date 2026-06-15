import Foundation

public enum ClipboardPlainTextRenderer {
    public static func plainText(for item: ClipboardItem) -> String {
        switch item.contentType {
        case .text:
            return item.payload.text ?? item.title
        case .url:
            return item.payload.urlString ?? item.title
        case .file:
            let paths = item.payload.allFileURLStrings.map { value in
                URL(string: value)?.path ?? value
            }
            return paths.isEmpty ? item.title : paths.joined(separator: "\n")
        case .image:
            return item.payload.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? item.payload.ocrText!
                : item.title
        case .mixed:
            let components = [
                item.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                item.payload.htmlString?.pasteBuddyPlainTextFromHTML.trimmingCharacters(in: .whitespacesAndNewlines),
                item.payload.urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
                item.payload.allFileURLStrings
                    .map { URL(string: $0)?.path ?? $0 }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                item.payload.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
                .compactMap { $0?.nilIfEmpty }
            var seen: Set<String> = []
            let uniqueComponents = components.filter { component in
                let key = component.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            return uniqueComponents.isEmpty ? item.title : uniqueComponents.joined(separator: "\n")
        }
    }

    public static func plainText(for items: [ClipboardItem]) -> String {
        items.map { plainText(for: $0) }.joined(separator: "\n")
    }
}
