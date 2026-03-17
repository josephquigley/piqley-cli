import Foundation

enum LexicalBuilder {
    static func build(title: String?, description: String?) -> String {
        var children: [[String: Any]] = []

        if let title, !title.isEmpty {
            children.append(makeParagraph(text: title))
        }
        if let description, !description.isEmpty {
            children.append(makeParagraph(text: description))
        }

        let root: [String: Any] = [
            "root": [
                "type": "root", "version": 1, "children": children,
                "direction": "ltr", "format": "", "indent": 0,
            ] as [String: Any]
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private static func makeParagraph(text: String) -> [String: Any] {
        [
            "type": "paragraph", "version": 1,
            "children": [
                ["type": "text", "version": 1, "text": text, "format": 0, "detail": 0, "mode": "normal", "style": ""] as [String: Any]
            ],
            "direction": "ltr", "format": "", "indent": 0, "textFormat": 0, "textStyle": "",
        ]
    }
}
