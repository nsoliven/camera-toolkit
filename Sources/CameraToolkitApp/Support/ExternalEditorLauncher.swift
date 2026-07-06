import AppKit
import CameraToolkitCore
import Foundation

struct ExternalEditorLauncher {
    private let workingCopyService: EditorWorkingCopyService
    private let workspace: NSWorkspace

    init(
        workingCopyService: EditorWorkingCopyService = EditorWorkingCopyService(),
        workspace: NSWorkspace = .shared
    ) {
        self.workingCopyService = workingCopyService
        self.workspace = workspace
    }

    @discardableResult
    func openWorkingCopy(source: URL, editor: ExternalEditor, workingRoot: URL) throws -> URL {
        let workingCopy = try workingCopyService.makeWorkingCopy(source: source, workingRoot: workingRoot)

        if let bundleIdentifier = editor.bundleIdentifier {
            guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw ToolkitError.commandFailed("\(editor.displayName) is not installed on this Mac.")
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.open([workingCopy], withApplicationAt: appURL, configuration: configuration)
        } else {
            workspace.open(workingCopy)
        }

        return workingCopy
    }
}
