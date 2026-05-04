import SwiftUI

/// Redesigned bottom panel for `.text` nodes. Replaces the horizontal-card
/// strip with a tabbed surface: a dark capsule TabBar (Text / Style /
/// Layout), a format toolbar, and an inline HSV color picker. Drives the
/// existing `NodeStyle` fields plus the three new ones added for this
/// design (`textItalic`, `textStrikethrough`, `letterSpacing`).
struct TextInspectorV2: View {
    @Binding var document: ProfileDocument
    let textID: UUID
    var selectedTextRange: NSRange?

    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onClose: () -> Void

    enum PickerTarget: Hashable { case textColor, highlight }

    @State private var selectedTabIndex: Int = 0
    @State private var pickerTarget: PickerTarget = .textColor
    @State private var sizeOpen: Bool = false
    @State private var paragraphPreset: ParagraphPreset = .body
    /// Drives the font-family picker sheet. Set to true by the
    /// toolbar's font button.
    @State private var fontPickerOpen: Bool = false

    var body: some View {
        ElementInspectorChrome(
            typeLabel: "TEXT",
            idTag: ElementInspectorChrome<EmptyView>.idTag(for: textID),
            tabs: ["Text", "Style", "Layout"],
            selectedIndex: $selectedTabIndex,
            onDuplicate: onDuplicate,
            onDelete: onDelete,
            onClose: onClose
        ) {
            Group {
                switch selectedTabIndex {
                case 0: textTab
                case 1: styleTab
                default: layoutTab
                }
            }
        }
    }

    // MARK: Text tab

    @ViewBuilder
    private var textTab: some View {
        VStack(spacing: 0) {
            inlineTextarea
            formatToolbar
            if sizeOpen {
                sizeDrawer
                Divider().background(Color.cucuInk.opacity(0.08))
            }
            colorPickerDrawer
        }
    }

    private var inlineTextarea: some View {
        TextField("Text", text: bindingNodeText(textID),
                  axis: .vertical)
            .lineLimit(2...6)
            .font(.cucuSans(14, weight: .regular))
            .foregroundStyle(Color.cucuInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.cucuInk.opacity(0.16), lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }

    // MARK: Format toolbar

    private var formatToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                paragraphPresetButton
                vRule
                fontFamilyButton
                vRule
                textColorButton
                highlightButton
                vRule
                weightButton
                italicButton
                underlineButton
                strikeButton
                vRule
                sizeButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.cucuCard)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cucuInk.opacity(0.08)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.cucuInk.opacity(0.08)).frame(height: 1)
        }
        // Modal font grid. Selection writes through `writeFontFamily`
        // which targets either the active text selection (per-span
        // override) or the whole node (`style.fontFamily` + clear
        // overlapping spans).
        .sheet(isPresented: $fontPickerOpen) {
            FontPickerSheet(
                selection: fontPickerBinding,
                onCommit: {}
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Toolbar tile that opens `FontPickerSheet`. Shows the currently-
    /// effective family — inline override (if a selection lives inside
    /// a styled span) wins over the node's `style.fontFamily`. The
    /// glyph is rendered in the family's own face so the user can read
    /// the current pick at a glance.
    private var fontFamilyButton: some View {
        let family = currentFontFamily
        return Button {
            fontPickerOpen = true
        } label: {
            HStack(spacing: 4) {
                Text("Aa")
                    .font(family.swiftUIFont(size: 14, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.cucuInk.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Font family")
    }

    private var vRule: some View {
        Rectangle()
            .fill(Color.cucuInk.opacity(0.14))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private var paragraphPresetButton: some View {
        Button {
            paragraphPreset = paragraphPreset.next
            paragraphPreset.apply(to: textID, in: $document)
        } label: {
            HStack(spacing: 4) {
                Text(paragraphPreset.label)
                    .font(.cucuSans(13, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.cucuInk.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
    }

    private var textColorButton: some View {
        toolbarButton(active: pickerTarget == .textColor) {
            pickerTarget = .textColor
        } content: {
            VStack(spacing: 1) {
                Text("A")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(Color.cucuInk)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(currentTextColor)
                    .frame(width: 18, height: 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .stroke(Color.cucuInk.opacity(0.35), lineWidth: 0.5)
                    )
            }
        }
    }

    private var highlightButton: some View {
        toolbarButton(active: pickerTarget == .highlight) {
            pickerTarget = .highlight
        } content: {
            ZStack {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
            }
        }
    }

    private var weightButton: some View {
        let isBold = (currentNode?.style.fontWeight ?? .regular) == .bold ||
                     (currentNode?.style.fontWeight ?? .regular) == .semibold
        return toolbarButton(active: isBold) {
            mutate { $0.style.fontWeight = isBold ? .regular : .bold }
        } content: {
            Text("B").font(.system(size: 14, weight: .heavy))
        }
    }

    private var italicButton: some View {
        let isItalic = currentNode?.style.textItalic == true
        return toolbarButton(active: isItalic) {
            mutate { $0.style.textItalic = isItalic ? nil : true }
        } content: {
            Text("I")
                .font(.custom("Georgia-Italic", size: 14))
                .italic()
        }
    }

    private var underlineButton: some View {
        let isOn = currentNode?.style.textUnderlined == true
        return toolbarButton(active: isOn) {
            mutate { $0.style.textUnderlined = isOn ? nil : true }
        } content: {
            Text("U")
                .font(.system(size: 14, weight: .semibold))
                .underline()
        }
    }

    private var strikeButton: some View {
        let isOn = currentNode?.style.textStrikethrough == true
        return toolbarButton(active: isOn) {
            mutate { $0.style.textStrikethrough = isOn ? nil : true }
        } content: {
            Text("S")
                .font(.system(size: 14, weight: .semibold))
                .strikethrough()
        }
    }

    private var sizeButton: some View {
        Button {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                sizeOpen.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text("Aa")
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(Color.cucuInk)
                Text("\(currentSize)")
                    .font(.cucuMono(11, weight: .regular))
                    .foregroundStyle(Color.cucuInk)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(sizeOpen ? Color.cucuInk.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func toolbarButton<Label: View>(active: Bool,
                                            action: @escaping () -> Void,
                                            @ViewBuilder content: () -> Label) -> some View {
        Button(action: action) {
            content()
                .frame(minWidth: 32)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.cucuInk.opacity(0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Size drawer

    private var sizeDrawer: some View {
        HStack(spacing: 10) {
            Text("SIZE")
                .font(.cucuMono(11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.cucuInk.opacity(0.6))
            Slider(
                value: bindingStyleDouble(textID, key: \.fontSize, defaultValue: 17),
                in: 8...72,
                step: 1
            )
            Text("\(currentSize)pt")
                .font(.cucuMono(12, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Color picker drawer

    /// When the user is editing the highlight target the grayscale
    /// palette rides along inside the same `cucuCard` surface as the
    /// HSV picker, so the two read as one drawer rather than a stack
    /// of unrelated rows. The wrapping `VStack` clips both children to
    /// the same rounded shape via the picker's own background — no
    /// separate corner-radius work needed because the grayscale row
    /// sits flush above the picker's existing padded card.
    @ViewBuilder
    private var colorPickerDrawer: some View {
        let picker = HSVColorPicker(
            hex: pickerHexBinding,
            alpha: pickerAlphaBinding,
            onBack: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    pickerTarget = .textColor
                }
            }
        )
        if pickerTarget == .highlight {
            VStack(spacing: 0) {
                grayscaleHighlightPalette
                    .background(Color.cucuCard)
                picker
            }
        } else {
            picker
        }
    }

    // MARK: Grayscale highlight palette

    /// Neutral / earthy highlight tones mirroring the "Grayscale" row in
    /// the inspector mock — kept on the warm side of true gray so the
    /// swatches still read as paper-like highlights, not screen-gray.
    /// Exposed at module scope so the keyboard-up
    /// `RichTextSelectionToolbar` can render the same palette without
    /// drifting from the panel inspector.
    static let grayscaleHighlightHexes = [
        "#F4E8D4", "#D5D5D5", "#3F4030", "#6B4A2A",
        "#4A4A4A", "#A8A8A8", "#7A7A7A", "#C8C8C8"
    ]

    private var grayscaleHighlightPalette: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grayscale")
                .font(.cucuSans(13, weight: .semibold))
                .foregroundStyle(Color.cucuInk)
            HStack(spacing: 6) {
                ForEach(Self.grayscaleHighlightHexes, id: \.self) { hex in
                    grayscaleSwatch(hex: hex)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func grayscaleSwatch(hex: String) -> some View {
        let isSelected = currentHighlightSelectionHex == hex
        return Button {
            applyGrayscaleHighlight(hex: hex)
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: hex))
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.cucuInk.opacity(isSelected ? 1 : 0.18),
                                lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grayscale highlight \(hex)")
    }

    /// What the active selection (or whole-text fallback) currently
    /// resolves to for highlight. Used to outline the matching swatch.
    /// Compared case-insensitively against the palette's canonical
    /// uppercase hexes so a stored `#f4e8d4` still highlights its row.
    private var currentHighlightSelectionHex: String? {
        guard let node = currentNode else { return nil }
        let range = normalizedRange(selection: activeSelectedTextRange,
                                    text: node.content.text ?? "")
        return inlineHighlightHex(in: node, range: range)?.uppercased()
    }

    private func applyGrayscaleHighlight(hex: String) {
        mutate { node in
            let range = normalizedRange(selection: activeSelectedTextRange,
                                        text: node.content.text ?? "")
            applyHighlight(hex: hex, range: range, to: &node)
        }
    }

    // MARK: Style tab

    private var styleTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                fieldSlider(label: "LETTER SPACING",
                            valueText: letterSpacingValueText,
                            value: bindingStyleOptionalDouble(textID, key: \.letterSpacing, defaultValue: 0),
                            range: -2...10, step: 0.1)
                fieldSlider(label: "LINE HEIGHT",
                            valueText: "\(Int(currentNode?.style.lineSpacing ?? 0))pt",
                            value: bindingStyleOptionalDouble(textID, key: \.lineSpacing, defaultValue: 0),
                            range: 0...16, step: 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("BACKGROUND")
                bgSwatchRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opacity controls the alpha byte of the stored
            // backgroundColorHex. When the user has the "transparent"
            // swatch selected (hex is nil), nudging the slider seeds a
            // white fill at that alpha so the slider always produces a
            // visible result instead of doing nothing on the first
            // drag.
            fieldSlider(label: "BG OPACITY",
                        valueText: bgOpacityValueText,
                        value: backgroundAlphaBinding,
                        range: 0...1, step: 0.01)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("BORDER")
                borderSwatchRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            fieldSlider(label: "BORDER WIDTH",
                        valueText: String(format: "%.1fpt", currentNode?.style.borderWidth ?? 0),
                        value: borderWidthBinding,
                        range: 0...8, step: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var bgSwatchRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.bgSwatchHexes, id: \.self) { hex in
                let isSelected = isBackgroundSelected(hex)
                Button {
                    mutate {
                        if hex == "transparent" {
                            $0.style.backgroundColorHex = nil
                        } else {
                            $0.style.backgroundColorHex = hex
                        }
                    }
                } label: {
                    swatchCircle(hex: hex, selected: isSelected)
                }
                .buttonStyle(.plain)
            }
            // Custom color tile — mirrors the border row's ColorPicker
            // tail so the user can pick any color (and adjust alpha
            // inline via the system picker) without leaving the panel.
            // `supportsOpacity: true` here too so the picker's own
            // alpha slider stays in sync with the BG OPACITY field
            // below.
            ColorPicker("", selection: backgroundColorHexBinding.asColor(), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 26, height: 26)
                .accessibilityLabel("Custom background color")
        }
    }

    /// Compares the candidate swatch against the stored hex while
    /// ignoring any trailing alpha byte — the swatch palette is
    /// six-char hex only, so a stored `#FFE3ECCC` (the same color at
    /// 80%) should still light up the matching swatch.
    private func isBackgroundSelected(_ hex: String) -> Bool {
        let current = currentNode?.style.backgroundColorHex
        if hex == "transparent" {
            return current == nil
        }
        guard let current else { return false }
        return Self.splitHex(current).rgb.uppercased() == hex.uppercased()
    }

    private static let bgSwatchHexes = [
        "transparent", "#FFE3EC", "#FFF1B8", "#DDF1D5", "#D9E5F5", "#3A1A1F"
    ]

    private var borderSwatchRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.borderSwatchHexes, id: \.self) { hex in
                let isSelected = isBorderSelected(hex)
                Button {
                    mutate {
                        if hex == "transparent" {
                            $0.style.borderColorHex = nil
                        } else {
                            $0.style.borderColorHex = hex
                        }
                    }
                } label: {
                    swatchCircle(hex: hex, selected: isSelected)
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: borderColorHexBinding.asColor(), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26, height: 26)
                .accessibilityLabel("Custom border color")
        }
    }

    private var borderColorHexBinding: Binding<String> {
        Binding(
            get: { currentNode?.style.borderColorHex ?? "#1A140E" },
            set: { newHex in
                mutate { $0.style.borderColorHex = newHex }
            }
        )
    }

    private var backgroundColorHexBinding: Binding<String> {
        Binding(
            get: { currentNode?.style.backgroundColorHex ?? "#FFFFFF" },
            set: { newHex in
                mutate { $0.style.backgroundColorHex = newHex }
            }
        )
    }

    /// Slider binding for the background's alpha byte. Reads the
    /// alpha out of the stored `#RRGGBB[AA]` form via `splitHex`.
    /// Writing seeds `#FFFFFF` as the rgb base when the user has the
    /// transparent swatch selected so dragging the slider always
    /// produces a visible fill instead of being a no-op against a
    /// nil background. Snapping the slider back to 0 clears the hex
    /// entirely (round-trips with the transparent swatch).
    private var backgroundAlphaBinding: Binding<Double> {
        Binding(
            get: {
                guard let hex = currentNode?.style.backgroundColorHex else { return 0 }
                return Self.splitHex(hex).alpha
            },
            set: { newAlpha in
                let clamped = max(0, min(1, newAlpha))
                if clamped <= 0.001 {
                    mutate { $0.style.backgroundColorHex = nil }
                    return
                }
                let stored = currentNode?.style.backgroundColorHex ?? "#FFFFFF"
                let rgb = Self.splitHex(stored).rgb
                let merged = Self.mergeHex(rgb: rgb, alpha: clamped)
                mutate { $0.style.backgroundColorHex = merged }
            }
        )
    }

    private var bgOpacityValueText: String {
        guard let hex = currentNode?.style.backgroundColorHex else { return "0%" }
        return "\(Int(Self.splitHex(hex).alpha * 100))%"
    }

    private static let borderSwatchHexes = [
        "transparent", "#1A140E", "#B22A4A", "#3A1A1F", "#FFFFFF", "#D9E5F5"
    ]

    private func isBorderSelected(_ hex: String) -> Bool {
        let current = currentNode?.style.borderColorHex
        if hex == "transparent" {
            return current == nil
        }
        return (current ?? "") == hex
    }

    private var borderWidthBinding: Binding<Double> {
        Binding(
            get: { currentNode?.style.borderWidth ?? 0 },
            set: { newValue in
                mutate { $0.style.borderWidth = max(0, newValue) }
            }
        )
    }

    private func swatchCircle(hex: String, selected: Bool) -> some View {
        ZStack {
            if hex == "transparent" {
                Circle()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color.cucuInk.opacity(0.10), location: 0.5),
                            .init(color: Color.white, location: 0.5),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            } else {
                Circle().fill(Color(hex: hex))
            }
        }
        .frame(width: 26, height: 26)
        .overlay(
            Circle().stroke(Color.cucuInk.opacity(selected ? 1 : 0.18),
                            lineWidth: selected ? 2 : 1)
        )
    }

    // MARK: Layout tab

    private var layoutTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                fieldSlider(label: "X",
                            valueText: "\(Int(currentNode?.frame.x ?? 0))pt",
                            value: bindingFrameDouble(textID, key: \.x),
                            range: -200...500, step: 1)
                fieldSlider(label: "Y",
                            valueText: "\(Int(currentNode?.frame.y ?? 0))pt",
                            value: bindingFrameDouble(textID, key: \.y),
                            range: -200...1200, step: 1)
            }
            HStack(spacing: 14) {
                fieldSlider(label: "WIDTH",
                            valueText: "\(Int(currentNode?.frame.width ?? 0))pt",
                            value: bindingFrameDouble(textID, key: \.width),
                            range: 40...500, step: 1)
                fieldSlider(label: "HEIGHT",
                            valueText: "\(Int(currentNode?.frame.height ?? 0))pt",
                            value: bindingFrameDouble(textID, key: \.height),
                            range: 20...600, step: 1)
            }
            // Padding lives here (not Style) because it's how the box
            // around the text grows / shrinks — same family as
            // width / height. Radius pairs with padding so anyone
            // dialing in the text box's shape finds both knobs in
            // the same row instead of having to tab back to Style.
            HStack(spacing: 14) {
                fieldSlider(label: "PADDING",
                            valueText: "\(Int(currentNode?.style.padding ?? 0))pt",
                            value: bindingStyleOptionalDouble(textID, key: \.padding, defaultValue: 0),
                            range: 0...32, step: 1)
                fieldSlider(label: "RADIUS",
                            valueText: "\(Int(currentNode?.style.cornerRadius ?? 0))pt",
                            value: cornerRadiusBinding,
                            range: 0...60, step: 1)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("ALIGN")
                    alignmentSegmented
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                fieldSlider(label: "OPACITY",
                            valueText: "\(Int((currentNode?.opacity ?? 1) * 100))%",
                            value: Binding(
                                get: { (currentNode?.opacity ?? 1) * 100 },
                                set: { newValue in
                                    mutateNode { $0.opacity = max(0, min(1, newValue / 100)) }
                                }
                            ),
                            range: 0...100, step: 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// `NodeStyle.cornerRadius` is a non-optional `Double` (defaults
    /// to 0), so neither `bindingStyleDouble` nor
    /// `bindingStyleOptionalDouble` fits — both expect an optional
    /// keypath. Inline binding clamps to >= 0 so dragging the slider
    /// past zero never produces a negative radius.
    private var cornerRadiusBinding: Binding<Double> {
        Binding(
            get: { currentNode?.style.cornerRadius ?? 0 },
            set: { newValue in
                mutate { $0.style.cornerRadius = max(0, newValue) }
            }
        )
    }

    private var alignmentSegmented: some View {
        HStack(spacing: 4) {
            alignChip(.leading, system: "text.alignleft")
            alignChip(.center,  system: "text.aligncenter")
            alignChip(.trailing, system: "text.alignright")
        }
    }

    private func alignChip(_ value: NodeTextAlignment, system: String) -> some View {
        let active = (currentNode?.style.textAlignment ?? .leading) == value
        return Button {
            mutate { $0.style.textAlignment = value }
        } label: {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Color.cucuCard : Color.cucuInk)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? Color.cucuInk : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.cucuInk.opacity(active ? 0 : 0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Field helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.cucuMono(9, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Color.cucuInk.opacity(0.6))
    }

    private func fieldSlider(label: String,
                             valueText: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                Text(valueText)
                    .font(.cucuMono(11, weight: .semibold))
                    .foregroundStyle(Color.cucuInk)
                    .frame(width: 44, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Bindings

    private var currentNode: CanvasNode? { document.nodes[textID] }
    private var currentSize: Int {
        Int(currentNode?.style.fontSize ?? 17)
    }
    private var currentTextColor: Color {
        Color(hex: currentTextColorHex)
    }

    private var currentTextColorHex: String {
        guard let node = currentNode else { return "#1A140E" }
        if let range = activeSelectedTextRange,
           let inline = inlineTextColorHex(in: node, range: range) {
            return inline
        }
        return node.style.textColorHex ?? "#1A140E"
    }

    /// Family that should drive the toolbar's Font preview glyph.
    /// Mirrors the color resolver: inline span overlapping the active
    /// selection wins, otherwise the node-level `style.fontFamily`,
    /// otherwise `.system`.
    private var currentFontFamily: NodeFontFamily {
        guard let node = currentNode else { return .system }
        if let range = activeSelectedTextRange,
           let inline = inlineFontFamily(in: node, range: range) {
            return inline
        }
        return node.style.fontFamily ?? .system
    }

    /// Binding the picker sheet writes through. Reading delegates to
    /// `currentFontFamily`. Writing routes to `writeFontFamily(_:)`
    /// which respects the selection-vs-node-wide rule.
    private var fontPickerBinding: Binding<NodeFontFamily> {
        Binding(
            get: { currentFontFamily },
            set: { writeFontFamily($0) }
        )
    }

    /// Selection wins when the user has a non-empty highlight inside
    /// the text view — that range gets a per-span `fontFamily`
    /// override. With no selection (or a collapsed cursor) the change
    /// hits the whole node via `style.fontFamily` and any leftover
    /// per-span overrides are cleared so they can't shadow the new
    /// node-wide choice.
    private func writeFontFamily(_ family: NodeFontFamily) {
        mutate { node in
            if let range = activeSelectedTextRange {
                applyFontFamily(family, range: range, to: &node)
            } else {
                node.style.fontFamily = family
                let range = normalizedRange(selection: nil, text: node.content.text ?? "")
                clearFontFamily(range: range, from: &node)
            }
        }
    }

    private var letterSpacingValueText: String {
        let value = currentNode?.style.letterSpacing ?? 0
        if abs(value) < 0.01 { return "0" }
        return String(format: "%.1fpt", value)
    }

    private var pickerHexBinding: Binding<String> {
        Binding(
            get: {
                let stored = storedTargetHex(default: pickerTarget == .highlight ? "#FFD93D" : "#1A140E")
                return Self.splitHex(stored).rgb
            },
            set: { newRgb in
                let alpha = Self.splitHex(storedTargetHex(default: "#000000")).alpha
                let merged = Self.mergeHex(rgb: newRgb, alpha: alpha)
                writeTargetHex(merged)
            }
        )
    }

    private var pickerAlphaBinding: Binding<Double> {
        Binding(
            get: {
                Self.splitHex(storedTargetHex(default: pickerTarget == .highlight ? "#FFD93D" : "#1A140E")).alpha
            },
            set: { newAlpha in
                let rgb = Self.splitHex(storedTargetHex(default: "#000000")).rgb
                let merged = Self.mergeHex(rgb: rgb, alpha: newAlpha)
                writeTargetHex(merged)
            }
        )
    }

    /// Reads the hex currently bound to whichever target the picker is
    /// editing. Falls back to the supplied default when the field is
    /// nil/empty so the picker's HSV state is always populated.
    private func storedTargetHex(default fallback: String) -> String {
        guard let node = currentNode else { return fallback }
        switch pickerTarget {
        case .textColor:
            let raw = currentTextColorHex
            return raw.isEmpty ? fallback : raw
        case .highlight:
            let range = normalizedRange(selection: activeSelectedTextRange,
                                        text: node.content.text ?? "")
            return inlineHighlightHex(in: node, range: range) ?? fallback
        }
    }

    private func writeTargetHex(_ hex: String) {
        mutate { node in
            switch pickerTarget {
            case .textColor:
                if let range = activeSelectedTextRange {
                    applyTextColor(hex: hex, range: range, to: &node)
                } else {
                    node.style.textColorHex = hex
                    node.style.textColorAuto = false
                    let range = normalizedRange(selection: nil, text: node.content.text ?? "")
                    clearTextColor(range: range, from: &node)
                }
            case .highlight:
                let range = normalizedRange(selection: activeSelectedTextRange,
                                            text: node.content.text ?? "")
                applyHighlight(hex: hex, range: range, to: &node)
            }
        }
    }

    /// Decompose a `#RRGGBB` or `#RRGGBBAA` value into a 6-char rgb
    /// string + alpha (0...1). Uses the same parsing rules as
    /// `Color(hex:)` so the picker's view of "what's stored" matches
    /// what the renderer will display. Returns ink black + opaque on
    /// malformed input rather than crashing — the picker's cursor will
    /// just show top-left of the saturation square.
    static func splitHex(_ hex: String) -> (rgb: String, alpha: Double) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if cleaned.count == 8,
           let alphaByte = UInt8(String(cleaned.suffix(2)), radix: 16) {
            return ("#" + String(cleaned.prefix(6)).uppercased(),
                    Double(alphaByte) / 255)
        }
        if cleaned.count == 6 {
            return ("#" + cleaned.uppercased(), 1.0)
        }
        return ("#1A140E", 1.0)
    }

    /// Combine a 6-char rgb with an alpha value into the canonical
    /// hex form. Drops the alpha byte entirely when the user has the
    /// slider at 100% so opaque colors round-trip as `#RRGGBB`
    /// (matches every default in the codebase) instead of
    /// `#RRGGBBFF`.
    static func mergeHex(rgb: String, alpha: Double) -> String {
        let cleaned = rgb.hasPrefix("#") ? String(rgb.dropFirst()) : rgb
        let safe6: String
        if cleaned.count == 6 {
            safe6 = cleaned.uppercased()
        } else if cleaned.count == 8 {
            safe6 = String(cleaned.prefix(6)).uppercased()
        } else {
            safe6 = "1A140E"
        }
        let clamped = max(0, min(1, alpha))
        if clamped >= 0.999 { return "#" + safe6 }
        let alphaByte = Int((clamped * 255).rounded())
        return String(format: "#%@%02X", safe6, alphaByte)
    }

    private func bindingNodeText(_ id: UUID) -> Binding<String> {
        Binding(
            get: { document.nodes[id]?.content.text ?? "" },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                let oldText = node.content.text ?? ""
                node.content.text = newValue
                reconcileTextStyleSpans(afterTextChangeFrom: oldText, to: newValue, in: &node)
                document.nodes[id] = node
            }
        )
    }

    private var activeSelectedTextRange: NSRange? {
        guard let node = currentNode,
              selectedTextRange?.length ?? 0 > 0 else {
            return nil
        }
        let range = normalizedRange(selection: selectedTextRange, text: node.content.text ?? "")
        return range.length > 0 ? range : nil
    }

    private func bindingStyleDouble(_ id: UUID,
                                    key: WritableKeyPath<NodeStyle, Double?>,
                                    defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style[keyPath: key] ?? defaultValue },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }

    private func bindingStyleOptionalDouble(_ id: UUID,
                                            key: WritableKeyPath<NodeStyle, Double?>,
                                            defaultValue: Double = 0) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.style[keyPath: key] ?? defaultValue },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.style[keyPath: key] = abs(newValue) > 0.001 ? newValue : nil
                document.nodes[id] = node
            }
        )
    }

    private func bindingFrameDouble(_ id: UUID,
                                    key: WritableKeyPath<NodeFrame, Double>) -> Binding<Double> {
        Binding(
            get: { document.nodes[id]?.frame[keyPath: key] ?? 0 },
            set: { newValue in
                guard var node = document.nodes[id] else { return }
                node.frame[keyPath: key] = newValue
                document.nodes[id] = node
            }
        )
    }

    private func mutate(_ change: (inout CanvasNode) -> Void) {
        guard var node = document.nodes[textID] else { return }
        change(&node)
        document.nodes[textID] = node
    }

    private func mutateNode(_ change: (inout CanvasNode) -> Void) { mutate(change) }
}

// MARK: - Paragraph presets

extension TextInspectorV2 {
    enum ParagraphPreset: String, CaseIterable {
        case title, heading, subhead, body, caption

        var label: String {
            switch self {
            case .title: return "Title"
            case .heading: return "Heading"
            case .subhead: return "Subhead"
            case .body: return "Body"
            case .caption: return "Caption"
            }
        }

        var next: ParagraphPreset {
            let all = ParagraphPreset.allCases
            let idx = all.firstIndex(of: self) ?? 0
            return all[(idx + 1) % all.count]
        }

        /// Pick the size + weight that this preset implies; values match
        /// the JSX prototype's expected hierarchy.
        var size: Double {
            switch self {
            case .title:   return 32
            case .heading: return 24
            case .subhead: return 18
            case .body:    return 15
            case .caption: return 12
            }
        }
        var weight: NodeFontWeight {
            switch self {
            case .title, .heading: return .bold
            case .subhead:         return .semibold
            case .body:            return .regular
            case .caption:         return .medium
            }
        }

        func apply(to id: UUID, in document: Binding<ProfileDocument>) {
            var doc = document.wrappedValue
            guard var node = doc.nodes[id] else { return }
            node.style.fontSize = size
            node.style.fontWeight = weight
            doc.nodes[id] = node
            document.wrappedValue = doc
        }
    }
}
