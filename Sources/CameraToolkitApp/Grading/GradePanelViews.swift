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
                    .help(look == .none ? "The converted picture with no look on top" : "Put \(name(look)) on top of the converted picture")
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
    /// A strip at the bottom left to the player's own controls: drags
    /// there go to the player. The picture is still measured in the whole
    /// pane, so the line sits exactly where the frame is split.
    var controlsInset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fittedRect(content: videoSize, in: geometry.size)
            let x = Self.lineX(wipe: wipe, picture: frame)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: frame.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: x, y: frame.midY)
                    .allowsHitTesting(false)
                Circle()
                    .fill(.white)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black.opacity(0.75))
                    }
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: x, y: min(frame.midY, geometry.size.height - controlsInset - 20))
                wipeLabel("Original")
                    .position(x: max(frame.minX + 44, x - 52), y: frame.minY + 22)
                    .opacity(wipe > 0.12 ? 1 : 0)
                wipeLabel("Graded")
                    .position(x: min(frame.maxX - 44, x + 50), y: frame.minY + 22)
                    .opacity(wipe < 0.88 ? 1 : 0)
            }
            .contentShape(Path(CGRect(x: 0, y: 0, width: geometry.size.width, height: max(0, geometry.size.height - controlsInset))))
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

    /// Where the divider is drawn for a wipe fraction: the same fraction
    /// of the picture's width the composition splits the frame at.
    static func lineX(wipe: Double, picture: CGRect) -> CGFloat {
        picture.minX + picture.width * min(max(wipe, 0), 1)
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
///
/// Every row can shrink to the card: long text wraps or truncates, nothing
/// is `fixedSize` horizontally. A row wider than the card made SwiftUI
/// centre the whole column on it, so labels started left of the glass and
/// values were cut off on the right.
struct GradePanel: View {
    /// The card's width beside the picture.
    static let cardWidth: CGFloat = 290
    /// Inset of the content from the card's edges.
    static let contentInset: CGFloat = 14
    static let cardCornerRadius: CGFloat = 18
    /// The coordinate space `GradePanelContentFrameKey` is measured in.
    static let cardSpace = "GradePanelCard"

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
                .frame(maxWidth: .infinity)
                .help(session.isLog
                      ? "Graded, split (drag the line on the picture), or the untouched log original (B toggles)"
                      : "Graded, split (drag the line on the picture), or the untouched original (B toggles)")

                Text(session.orderLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                stage(1, "Conversion", icon: "arrow.right.circle") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.conversionTitle(session.recipe))
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !session.conversionChoices.isEmpty {
                            Menu {
                                ForEach(session.conversionChoices, id: \.self) { choice in
                                    Button {
                                        session.setConversion(choice)
                                    } label: {
                                        if choice == session.draft.conversion {
                                            Label(session.conversionName(choice), systemImage: "checkmark")
                                        } else {
                                            Text(session.conversionName(choice))
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .menuStyle(.button)
                            .buttonStyle(.borderless)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Log → Rec.709 for this clip. The default for every clip is set in Settings › Color.")
                        }
                    }
                    if !session.isConversionAvailable {
                        Label("The conversion LUT is missing — import it again in Settings › Color.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                stage(2, "Look", icon: "camera.filters") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.lookName(session.draft.look))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if !session.canTakeLook {
                            Text("Needs the conversion")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if !session.isLookAvailable {
                            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help("This look LUT is not in Settings › Color any more. Import it again to use it.")
                        }
                    }
                    control("Intensity", value: $session.draft.intensity, range: ClipGrade.ranges.intensity, reset: session.draft.look.defaultIntensity) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                    .disabled(session.draft.look == .none || !session.canTakeLook)
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
                        .lineLimit(1)
                        .help("Copy this grade (⌘⌥C)")
                    Button("Paste", systemImage: "doc.on.clipboard", action: onPaste)
                        .lineLimit(1)
                        .disabled(!canPaste)
                        .help("Paste the copied grade onto this clip (⌘⌥V)")
                    Spacer(minLength: 0)
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
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(session.recipe.isIdentity || !session.isConversionAvailable)
                        if let renderNote {
                            Text(renderNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: GradePanelContentFrameKey.self, value: proxy.frame(in: .named(Self.cardSpace)))
                }
            }
            .padding(Self.contentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .coordinateSpace(.named(Self.cardSpace))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Grade")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(session.isSaved ? "Saved" : "Editing…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// A numbered stage heading: 1 Conversion, 2 Look.
    private func stage<Content: View>(_ number: Int, _ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .frame(width: 16, height: 16)
                    .background(.secondary.opacity(0.25), in: Circle())
                Label(title, systemImage: icon)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(format(value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(value.wrappedValue == reset ? .secondary : .primary)
                    .lineLimit(1)
                    .layoutPriority(1)
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

/// The panel content's frame in the card (`GradePanel.cardSpace`), so a
/// test can prove nothing spills past the glass.
struct GradePanelContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    /// The grade panel's glass card beside the picture: a fixed width the
    /// content is laid out in, clipped to the card so nothing can paint
    /// over the video, on dark glass whatever the window's appearance.
    func gradeInspectorCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: GradePanel.cardCornerRadius, style: .continuous)
        return frame(width: GradePanel.cardWidth)
            .frame(maxHeight: .infinity)
            .foregroundStyle(.white, .white.opacity(0.65), .white.opacity(0.45))
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .environment(\.colorScheme, .dark)
    }
}
