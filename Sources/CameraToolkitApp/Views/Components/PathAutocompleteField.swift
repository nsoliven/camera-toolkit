import AppKit
import SwiftUI

struct PathAutocompleteField: NSViewRepresentable {
    @Binding var path: String
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(path: $path)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: path)
        textField.placeholderString = placeholder
        textField.delegate = context.coordinator
        textField.isEditable = true
        textField.isSelectable = true
        textField.lineBreakMode = .byTruncatingMiddle
        textField.bezelStyle = .roundedBezel
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.path = $path
        if nsView.stringValue != path {
            nsView.stringValue = path
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var path: Binding<String>

        init(path: Binding<String>) {
            self.path = path
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            path.wrappedValue = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>
        ) -> [String] {
            completionSuggestions(for: textView.string, range: charRange)
        }

        private func completionSuggestions(for text: String, range: NSRange) -> [String] {
            let nsText = text as NSString
            guard range.location <= nsText.length else { return [] }

            let prefix = nsText.substring(to: range.location)
            let partial = range.location + range.length <= nsText.length
                ? nsText.substring(with: range)
                : ""
            let directoryText = prefix.isEmpty ? "." : prefix
            let expandedDirectory = NSString(string: directoryText).expandingTildeInPath
            let directoryURL = URL(fileURLWithPath: expandedDirectory, isDirectory: true)

            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            let lowercasedPartial = partial.lowercased()
            let matches: [String] = urls
                .compactMap { url -> String? in
                    let name = url.lastPathComponent
                    guard lowercasedPartial.isEmpty || name.lowercased().hasPrefix(lowercasedPartial) else {
                        return nil
                    }
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return isDirectory ? "\(name)/" : name
                }
                .sorted()

            return Array(matches.prefix(20))
        }
    }
}
