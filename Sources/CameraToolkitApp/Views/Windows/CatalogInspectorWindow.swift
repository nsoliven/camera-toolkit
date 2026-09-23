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
            CameraToolkitWindowFactory.present(window)
            return
        }

        let catalogURL = URL(fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath))
        let window = CameraToolkitWindowFactory.make(
            .photoDatabase,
            identifier: "CameraToolkitCatalogInspectorWindow",
            title: "Photo List SQL Inspector",
            initialContentSize: NSSize(width: 1_120, height: 720),
            rootView: CatalogInspectorView(catalogURL: catalogURL)
        )
        window.delegate = self
        self.window = window
        CameraToolkitWindowFactory.present(window)
    }
}

private enum CatalogInspectorMode: String, CaseIterable, Identifiable {
    case rows = "Rows"
    case schema = "Schema"
    case sql = "SQL"

    var id: String { rawValue }
}

/// One result row for the native `Table` — the row's position is its
/// identity, since query results carry no key of their own.
struct CatalogResultRow: Identifiable, Equatable {
    let id: Int
    let values: [String]

    static func rows(from result: CatalogQueryResult) -> [CatalogResultRow] {
        result.rows.enumerated().map { CatalogResultRow(id: $0.offset, values: $0.element) }
    }

    /// The cell for one column, empty when a ragged row is short.
    func value(at column: Int) -> String {
        column < values.count ? values[column] : ""
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
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(selectedObjectName ?? "SQLite Catalog")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task { await reloadObjects() }
        .onChange(of: selectedObjectName) { _, _ in
            guard mode == .rows else { return }
            Task { await loadSelectedRows() }
        }
        .onChange(of: mode) { _, value in
            if value == .rows { Task { await loadSelectedRows() } }
        }
    }

    /// "Read only · catalog.sqlite · 42 rows" — the full path is the
    /// Reveal button's tooltip.
    private var subtitle: String {
        var parts = ["Read only", catalogURL.lastPathComponent]
        if mode != .schema, !result.columns.isEmpty {
            parts.append("\(result.rows.count) row\(result.rows.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $mode) {
                ForEach(CatalogInspectorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        ToolbarItem {
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([catalogURL])
            }
            .help("Reveal catalog in Finder — \(catalogURL.path)")
        }
        ToolbarItem {
            Button("Reload", systemImage: "arrow.clockwise") {
                Task { await reloadObjects() }
            }
            .help("Reload tables and rows")
        }
        if mode == .sql {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button {
                    Task { await runSQL() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Run the read-only query (⌘↩)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && result.columns.isEmpty {
            ProgressView("Reading SQLite catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView(
                "Couldn’t Read Catalog",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(errorMessage)
            )
        } else {
            switch mode {
            case .rows:
                resultTable
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
                }
                TextEditor(text: $sql)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110, maxHeight: 180)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
            }
            .padding(14)
            Divider()
            resultTable
        }
    }

    /// Query results as a native table: resizable columns, row selection,
    /// and ⌘C. Keyed on the column set so a query with different columns
    /// rebuilds the table instead of reusing stale column identities.
    @ViewBuilder
    private var resultTable: some View {
        if result.columns.isEmpty {
            ContentUnavailableView(
                mode == .rows ? "Choose a Table" : "Run a Query",
                systemImage: "tablecells",
                description: Text(mode == .rows ? "Select a SQLite table or view from the sidebar." : "Results appear here. Queries are capped at 500 rows.")
            )
        } else {
            let columns = result.columns
            Table(CatalogResultRow.rows(from: result)) {
                TableColumnForEach(columns.indices, id: \.self) { index in
                    TableColumn(columns[index]) { row in
                        Text(row.value(at: index))
                            .font(.caption.monospaced())
                            .lineLimit(3)
                            .help(row.value(at: index))
                    }
                    .width(min: 60, ideal: 180)
                }
            }
            .id(columns)
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
