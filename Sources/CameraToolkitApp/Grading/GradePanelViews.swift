import CameraToolkitCore
import SwiftUI

// MARK: - Tile badge

/// A tile's colour marker: a small filter glyph on a graded clip, a quiet
/// "S-Log3" tag on a log clip that is still flat.
struct TileGradeBadge: View {
    let mark: TileGradeMark

    var body: some View {
        switch mark {
        case .graded(let recipe):
            Image(systemName: "camera.filters")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: BoardMetrics.badgeMinHitSize, height: BoardMetrics.badgeMinHitSize)
                .background(Color.black.opacity(BoardMetrics.badgeScrimOpacity), in: Circle())
                .help(recipe.profile.map { "Graded from \($0.displayName). The original is untouched." } ?? "Graded. The original is untouched.")
                .accessibilityLabel("Graded")
        case .flatLog(let profile):
            Text(profile.shortName)
                .foregroundStyle(.white.opacity(0.78))
                .photoBadgeScrim()
                .help("\(profile.displayName) footage with no look yet — open it and choose one, or use Color › Apply Look to Log Clips.")
                .accessibilityLabel("\(profile.shortName), not graded")
        }
    }
}

// MARK: - Histogram

/// RGB histogram with a luma outline, drawn additively so overlaps go
/// white the way a scope does. Clipping shows as a tick at either end.
struct GradeHistogramView: View {
    let histogram: GradeHistogram?

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.black.opacity(0.35)))
            // Quarter guides.
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 4)); $0.addLine(to: CGPoint(x: x, y: size.height - 4)) },
                               with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
            guard let histogram else { return }
            context.blendMode = .plusLighter
            for (values, color) in [(histogram.red, Color(red: 1, green: 0.25, blue: 0.25)),
                                    (histogram.green, Color(red: 0.3, green: 1, blue: 0.35)),
                                    (histogram.blue, Color(red: 0.35, green: 0.5, blue: 1))] {
                context.fill(area(values, in: size), with: .color(color.opacity(0.55)))
            }
            context.blendMode = .normal
            context.stroke(line(histogram.luma, in: size), with: .color(.white.opacity(0.85)), lineWidth: 1)
            if histogram.highlightClipFraction > 0.005 {
                context.fill(Path(CGRect(x: size.width - 3, y: 0, width: 3, height: size.height)), with: .color(.orange))
            }
            if histogram.shadowClipFraction > 0.02 {
                context.fill(Path(CGRect(x: 0, y: 0, width: 3, height: size.height)), with: .color(.orange.opacity(0.8)))
            }
        }
        .accessibilityLabel("Histogram")
    }

    private func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        let inset: CGFloat = 4
        let height = size.height - inset * 2
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            CGPoint(x: CGFloat(index) * step, y: inset + height * (1 - CGFloat(value)))
        }
    }

    private func area(_ values: [Double], in size: CGSize) -> Path {
        Path { path in
            let pts = points(values, in: size)
            path.move(to: CGPoint(x: 0, y: size.height))
            for p in pts { path.addLine(to: p) }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }

    private func line(_ values: [Double], in size: CGSize) -> Path {
        Path { path in
            let pts = points(values, in: size)
            guard let first = pts.first else { return }
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
        }
    }
}

// MARK: - Look strip

/// Every look rendered from the current frame: choosing a look is clicking
/// a picture.
struct GradeLookStrip: View {
    let looks: [GradeLook]
    let selected: GradeLook
    let thumbnails: [GradeLook: CGImage]
    let name: (GradeLook) -> String
    let onChoose: (GradeLook) -> Void
    var thumbnailWidth: CGFloat = 132
    /// True over the preview's black backdrop; false in a sheet, where
    /// labels follow the window's light or dark appearance.
    var onDarkBackdrop = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(looks, id: \.self) { look in
                    Button {
                        onChoose(look)
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Color.black.opacity(0.4)
                                if let image = thumbnails[look] {
                                    Image(decorative: image, scale: 1)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    ProgressView().controlSize(.small).tint(.white)
                                }
                            }
                            .frame(width: thumbnailWidth, height: thumbnailWidth * 9 / 16)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(look == selected ? Color.accentColor : (onDarkBackdrop ? Color.white.opacity(0.15) : Color.primary.opacity(0.15)),
                                                  lineWidth: look == selected ? 2.5 : 1)
                            }
                            Text(name(look))
                                .font(.caption.weight(look == selected ? .semibold : .regular))
                                .foregroundStyle(labelStyle(selected: look == selected))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: thumbnailWidth)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(look == .rec709 ? "Built-in S-Log3 → Rec.709 conversion" : "Use \(name(look))")
                    .accessibilityAddTraits(look == selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

extension GradeLookStrip {
    fileprivate func labelStyle(selected: Bool) -> Color {
        if onDarkBackdrop { return selected ? .white : .white.opacity(0.75) }
        return selected ? .primary : .secondary
    }
}

// MARK: - Wipe

/// The before/after divider over the video: drag it anywhere across the
/// picture. Left of the line is the original, right of it the grade.
struct GradeWipeOverlay: View {
    @Binding var wipe: Double
    /// The video's pixel size, to find where the picture sits in the pane.
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fittedRect(content: videoSize, in: geometry.size)
            let x = frame.minX + frame.width * wipe
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: frame.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: x, y: frame.midY)
                Circle()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black.opacity(0.75))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: x, y: frame.midY)
                wipeLabel("Original")
                    .position(x: max(frame.minX + 44, x - 52), y: frame.minY + 22)
                    .opacity(wipe > 0.12 ? 1 : 0)
                wipeLabel("Graded")
                    .position(x: min(frame.maxX - 44, x + 50), y: frame.minY + 22)
                    .opacity(wipe < 0.88 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frame.width > 0 else { return }
                        wipe = min(max((value.location.x - frame.minX) / frame.width, 0), 1)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Before and after divider")
        .accessibilityValue("\(Int(wipe * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: wipe = min(1, wipe + 0.05)
            case .decrement: wipe = max(0, wipe - 0.05)
            @unknown default: break
            }
        }
    }

    private func wipeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }

    static func fittedRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}

// MARK: - Panel

/// The grade inspector beside the clip: scope, view mode, look, intensity,
/// the basic controls, copy/paste and render.
struct GradePanel: View {
    @Bindable var session: GradeSession
    var canPaste: Bool
    var onCopy: () -> Void
    var onPaste: () -> Void
    var onRemove: () -> Void
    var onMarkProfile: (ClipProfileMark) -> Void
    var onRender: (() -> Void)?
    var renderNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                GradeHistogramView(histogram: session.histogram)
                    .frame(height: 76)
                Picker("View", selection: $session.viewMode) {
                    ForEach(GradeViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Graded, split (drag the line on the picture), or the untouched original (B toggles)")

                section("Look", icon: "camera.filters") {
                    HStack {
                        Text(session.lookName(session.draft.look))
                            .font(.callout.weight(.medium))
                        Spacer()
                        if !session.isLookAvailable {
                            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help(unavailableHelp)
                        }
                    }
                    control("Intensity", value: $session.draft.intensity, range: ClipGrade.ranges.intensity, reset: 1) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                    .disabled(session.draft.look == .none)
                }

                section("Light", icon: "sun.max") {
                    control("Exposure", value: $session.draft.exposure, range: ClipGrade.ranges.exposure, reset: 0) {
                        String(format: "%+.2f", $0)
                    }
                    control("Contrast", value: $session.draft.contrast, range: ClipGrade.ranges.contrast, reset: 0) { signed($0) }
                }
                section("Color", icon: "paintpalette") {
                    control("Temperature", value: $session.draft.temperature, range: ClipGrade.ranges.temperature, reset: 0,
                            track: LinearGradient(colors: [.blue.opacity(0.7), .orange.opacity(0.8)], startPoint: .leading, endPoint: .trailing)) { signed($0) }
                    control("Tint", value: $session.draft.tint, range: ClipGrade.ranges.tint, reset: 0,
                            track: LinearGradient(colors: [.green.opacity(0.7), .pink.opacity(0.8)], startPoint: .leading, endPoint: .trailing)) { signed($0) }
                    control("Saturation", value: $session.draft.saturation, range: ClipGrade.ranges.saturation, reset: 0) { signed($0) }
                }

                HStack(spacing: 8) {
                    Button("Copy", systemImage: "doc.on.doc", action: onCopy)
                        .help("Copy this grade (⌘⌥C)")
                    Button("Paste", systemImage: "doc.on.clipboard", action: onPaste)
                        .disabled(!canPaste)
                        .help("Paste the copied grade onto this clip (⌘⌥V)")
                    Spacer()
                    Button("Reset", systemImage: "arrow.counterclockwise") { session.resetControls() }
                        .labelStyle(.iconOnly)
                        .help("Reset the sliders (the look stays)")
                    Menu {
                        Button("Remove Grade", systemImage: "xmark.circle", action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)

                if let onRender {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: onRender) {
                            Label("Render Graded Copy", systemImage: "square.and.arrow.down.on.square")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(session.recipe.grade.isIdentity || !session.isLookAvailable)
                        if let renderNote {
                            Text(renderNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Grade")
                    .font(.headline)
                Spacer()
                Text(session.isSaved ? "Saved" : "Editing…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Menu {
                Button("Use Camera Metadata") { onMarkProfile(.detected) }
                Divider()
                ForEach(LogProfile.allCases, id: \.self) { profile in
                    Button("Mark as \(profile.displayName)") { onMarkProfile(.marked(profile)) }
                }
                Button("Mark as Not Log") { onMarkProfile(.notLog) }
            } label: {
                Text(profileCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .fixedSize()
            .help("What the clip was shot in. DJI D-Log M clips don't say so in their files — mark them here.")
        }
    }

    private var profileCaption: String {
        switch session.draft.profileMark {
        case .detected:
            session.detectedProfile.map { "\($0.displayName) · from the camera" } ?? "Not log footage"
        case .marked(let profile):
            "\(profile.displayName) · marked"
        case .notLog:
            "Not log · marked"
        }
    }

    private var unavailableHelp: String {
        switch session.draft.look {
        case .rec709:
            "The built-in Rec.709 conversion is for Sony S-Log3. For D-Log M, import DJI's LUT in Settings › Color."
        case .lut:
            "This LUT is not in Settings › Color any more. Import it again to use it."
        case .none:
            ""
        }
    }

    private func signed(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded == 0 ? "0" : String(format: "%+d", rounded)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func control(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        reset: Double,
        track: LinearGradient? = nil,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(value.wrappedValue == reset ? .secondary : .primary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value.wrappedValue = reset }
            .help("Double-click to reset \(title.lowercased())")
            Slider(value: value, in: range)
                .controlSize(.small)
                .labelsHidden()
                .background(alignment: .center) {
                    if let track {
                        Capsule().fill(track).frame(height: 3).opacity(0.9).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel(title)
        }
    }
}
