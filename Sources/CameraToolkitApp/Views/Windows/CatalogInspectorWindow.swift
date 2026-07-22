import AppKit
import CameraToolkitCore
import SwiftUI

@MainActor
final class CatalogInspectorWindowController: NSObject, NSWindowDelegate {
    static let shared = CatalogInspectorWindowController()

    private var window: NSWindow?

    func show(model: DashboardModel) {
        model.syncCatalogCache()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let controller = NSHostingController(rootView: CatalogInspectorView(catalogURL: catalogURL))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Photo List SQL Inspector"
        window.identifier = NSUserInterfaceItemIdentifier("CameraToolkitCatalogInspectorWindow")
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        CameraToolkitWindowSizing.configure(window, as: .photoDatabase)
        window.setContentSize(NSSize(width: 1_120, height: 720))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

private enum CatalogInspectorMode: String, CaseIterable, Identifiable {
    case rows = "Rows"
    case schema = "Schema"
    case sql = "SQL"

    var id: String { rawValue }
}

private struct CatalogGridCell: View {
    var text: String
    var shaded: Bool = false
    var isHeader: Bool = false

    var body: some View {
        Text(text)
            .font(isHeader ? .caption.bold() : .system(.caption, design: .monospaced))
            .lineLimit(isHeader ? 1 : 3)
            .textSelection(.enabled)
            .frame(width: 190, alignment: .leading)
            .frame(minHeight: isHeader ? 0 : 30, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, isHeader ? 8 : 4)
            .background(isHeader ? Color(nsColor: .windowBackgroundColor) : (shaded ? Color.primary.opacity(0.035) : Color.clear))
            .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
    }
}

private struct CatalogInspectorView: View {
    let catalogURL: URL
    @State private var objects: [CatalogObject] = []
    @State private var selectedObjectName: String?
    @State private var result = CatalogQueryResult(columns: [], rows: [])
    @State private var mode: CatalogInspectorMode = .rows
    @State private var sql = "SELECT * FROM events ORDER BY event_date DESC;"
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var inspector: CatalogInspector { CatalogInspector(url: catalogURL) }
    private var selectedObject: CatalogObject? {
        objects.first { $0.name == selectedObjectName }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedObjectName) {
                Section("Tables") {
                    ForEach(objects.filter { $0.kind == "table" }) { object in
                        Label(object.name, systemImage: "tablecells")
                            .tag(Optional(object.name))
                    }
                }
                if objects.contains(where: { $0.kind == "view" }) {
                    Section("Views") {
                        ForEach(objects.filter { $0.kind == "view" }) { object in
                            Label(object.name, systemImage: "eye")
                                .tag(Optional(object.name))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .task { await reloadObjects() }
        .onChange(of: selectedObjectName) { _, _ in
            guard mode == .rows else { return }
            Task { await loadSelectedRows() }
        }
        .onChange(of: mode) { _, value in
            if value == .rows { Task { await loadSelectedRows() } }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedObjectName ?? "SQLite Catalog")
                    .font(.title2.bold())
                Text(catalogURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Label("GRDB · Read only", systemImage: "lock.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.12), in: Capsule())
            Picker("View", selection: $mode) {
                ForEach(CatalogInspectorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([catalogURL])
            } label: {
                Image(systemName: "folder")
            }
            .help("Reveal catalog in Finder")
            Button {
                Task { await reloadObjects() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload tables and rows")
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && result.columns.isEmpty {
            ProgressView("Reading SQLite catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn’t Read Catalog",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            switch mode {
            case .rows:
                resultGrid
            case .schema:
                schemaView
            case .sql:
                sqlView
            }
        }
    }

    private var schemaView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CREATE statement")
                    .font(.headline)
                Text(selectedObject?.sql.isEmpty == false ? selectedObject?.sql ?? "" : "No schema SQL is stored for this object.")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(18)
        }
    }

    private var sqlView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Read-only SQL", systemImage: "terminal")
                        .font(.headline)
                    Spacer()
                    Text("SELECT · WITH · PRAGMA · EXPLAIN")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Run") { Task { await runSQL() } }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                }
                TextEditor(text: $sql)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110, maxHeight: 180)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    }
            }
            .padding(14)
            Divider()
            resultGrid
        }
    }

    private var resultGrid: some View {
        Group {
            if result.columns.isEmpty {
                ContentUnavailableView(
                    mode == .rows ? "Choose a Table" : "Run a Query",
                    systemImage: "tablecells",
                    description: Text(mode == .rows ? "Select a SQLite table or view from the sidebar." : "Results appear here. Queries are capped at 500 rows.")
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(Array(result.rows.enumerated()), id: \.offset) { index, row in
                                HStack(spacing: 0) {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                                        CatalogGridCell(text: value, shaded: !index.isMultiple(of: 2))
                                    }
                                }
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 0) {
                                ForEach(Array(result.columns.enumerated()), id: \.offset) { _, column in
                                    CatalogGridCell(text: column, isHeader: true)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .defaultScrollAnchor(.topLeading)
                .overlay(alignment: .bottomTrailing) {
                    Text("\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
        }
    }

    @MainActor
    private func reloadObjects() async {
        isLoading = true
        errorMessage = nil
        do {
            let currentInspector = inspector
            let loaded = try await Task.detached { try currentInspector.objects() }.value
            objects = loaded
            if selectedObjectName == nil { selectedObjectName = loaded.first?.name }
            if mode == .rows { await loadSelectedRows() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func loadSelectedRows() async {
        guard let selectedObjectName else { return }
        isLoading = true
        errorMessage = nil
        do {
            let currentInspector = inspector
            result = try await Task.detached { try currentInspector.rows(in: selectedObjectName) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func runSQL() async {
        isLoading = true
        errorMessage = nil
        do {
            let currentInspector = inspector
            let queryText = sql
            result = try await Task.detached { try currentInspector.query(queryText) }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
