import PictureEditCore
import SwiftUI

/// What the panels ask of the window.
struct EditorActions {
    var rotate: (Bool) -> Void
    var flip: (Bool) -> Void
    var resetCrop: () -> Void
    var applyCrop: () -> Void
    var cropAspectChanged: () -> Void
    var insertPicture: () -> Void
}

// MARK: Tool strip

/// The strip under the toolbar while editing: the tools, then the style of what is selected or about
/// to be drawn (one row, no inspector to open), or the crop options.
struct EditorToolStrip: View {
    @ObservedObject var editor: PictureEditor
    let actions: EditorActions

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditTool.allCases) { tool in
                    Button { editor.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 26, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(editor.tool == tool ? Color.accentColor.opacity(0.25) : .clear))
                    .help("\(tool.title) (\(String(tool.key).uppercased()))")
                }
                Button(action: actions.insertPicture) {
                    Image(systemName: "photo.badge.plus").frame(width: 26, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Insert Picture")
            }
            Divider().frame(height: 20)
            if editor.tool == .crop {
                cropOptions
            } else if let style = editor.shownStyle, let kind = editor.shownKind {
                styleOptions(style, kind)
            } else {
                Text("Pick a tool, or click a shape to change it.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!editor.history.canUndo && editor.document == editor.history.current)
                .help("Undo")
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!editor.history.canRedo)
                .help("Redo")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var cropOptions: some View {
        HStack(spacing: 8) {
            Picker("Proportions", selection: Binding(get: { editor.cropAspect },
                                                    set: { editor.cropAspect = $0; actions.cropAspectChanged() })) {
                ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)
            Button { editor.cropPortrait.toggle(); actions.cropAspectChanged() } label: {
                Image(systemName: editor.cropPortrait ? "rectangle.portrait" : "rectangle")
            }
            .help("Portrait or Landscape")
            .disabled(editor.cropAspect == .free || editor.cropAspect == .original || editor.cropAspect == .square)
            Divider().frame(height: 20)
            Button { actions.rotate(false) } label: { Image(systemName: "rotate.left") }.help("Rotate Left")
            Button { actions.rotate(true) } label: { Image(systemName: "rotate.right") }.help("Rotate Right")
            Button { actions.flip(true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .help("Flip Horizontal")
            Button { actions.flip(false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }
                .help("Flip Vertical")
            Divider().frame(height: 20)
            Button("Reset", action: actions.resetCrop)
            Button("Crop", action: actions.applyCrop).keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func styleOptions(_ style: PictureEditCore.ShapeStyle, _ kind: PictureEditCore.Shape.Kind) -> some View {
        let unit = editor.unit
        HStack(spacing: 8) {
            if kind != .blur && kind != .pixelate && kind != .picture {
                HStack(spacing: 3) {
                    ForEach(RGBA.palette, id: \.self) { color in
                        Button { editor.changeStyle { $0.stroke = color.withAlpha($0.stroke.alpha) } } label: {
                            Circle()
                                .fill(Color(cgColor: color.cgColor))
                                .overlay(Circle().stroke(Color.primary.opacity(0.35), lineWidth: 0.5))
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2).padding(-3)
                                    .opacity(style.stroke.withAlpha(1) == color ? 1 : 0))
                                .frame(width: 15, height: 15)
                        }
                        .buttonStyle(.plain)
                    }
                    ColorPicker("Colour", selection: Binding(
                        get: { style.stroke.cgColor },
                        set: { color in editor.changeStyle { $0.stroke = RGBA(cgColor: color) } }))
                        .labelsHidden()
                }
            }
            if ([.rectangle, .ellipse, .line, .arrow, .pen, .highlighter] as [PictureEditCore.Shape.Kind]).contains(kind) {
                Menu {
                    ForEach([1.0, 2, 3, 5, 8, 12, 20], id: \.self) { level in
                        Button("\(Int(level))") { editor.changeStyle { $0.lineWidth = level * unit * (kind == .highlighter ? 4 : 1) } }
                    }
                } label: {
                    Label("Width \(Int((style.lineWidth / unit / (kind == .highlighter ? 4 : 1)).rounded()))",
                          systemImage: "lineweight")
                }
                .fixedSize()
                .help("Line Width")
            }
            if kind == .text || kind == .step {
                Menu {
                    ForEach([10.0, 12, 14, 18, 24, 32, 48, 72], id: \.self) { size in
                        Button("\(Int(size))") { editor.changeStyle { $0.fontSize = size * unit } }
                    }
                } label: {
                    Label("Size \(Int((style.fontSize / unit).rounded()))", systemImage: "textformat.size")
                }
                .fixedSize()
                .help("Text Size")
            }
            if kind == .rectangle || kind == .ellipse || kind == .text {
                Menu {
                    Button("No Fill") { editor.changeStyle { $0.fill = nil } }
                    Button("Same Colour, Lighter") { editor.changeStyle { $0.fill = $0.stroke.withAlpha(0.3) } }
                    Button("Same Colour") { editor.changeStyle { $0.fill = $0.stroke } }
                    Button("White") { editor.changeStyle { $0.fill = .white } }
                    Button("Black") { editor.changeStyle { $0.fill = .black } }
                } label: {
                    Label("Fill", systemImage: style.fill == nil ? "square.dashed" : "square.fill")
                }
                .fixedSize()
                .help("Fill")
            }
            if kind == .rectangle {
                Toggle(isOn: Binding(get: { style.cornerRadius > 0 },
                                     set: { on in editor.changeStyle { $0.cornerRadius = on ? 12 * unit : 0 } })) {
                    Image(systemName: "app")
                }
                .toggleStyle(.button)
                .help("Rounded Corners")
            }
            if ([.rectangle, .ellipse, .line, .arrow] as [PictureEditCore.Shape.Kind]).contains(kind) {
                Toggle(isOn: Binding(get: { style.dashed }, set: { on in editor.changeStyle { $0.dashed = on } })) {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .toggleStyle(.button)
                .help("Dashed")
            }
            if kind == .arrow {
                Toggle(isOn: Binding(get: { style.doubleHeaded }, set: { on in editor.changeStyle { $0.doubleHeaded = on } })) {
                    Image(systemName: "arrow.left.and.right")
                }
                .toggleStyle(.button)
                .help("Arrow at Both Ends")
            }
            if !kind.isMask && kind != .highlighter {
                Toggle(isOn: Binding(get: { style.shadow }, set: { on in editor.changeStyle { $0.shadow = on } })) {
                    Image(systemName: "shadow")
                }
                .toggleStyle(.button)
                .help("Shadow")
            }
            if kind != .blur && kind != .pixelate {
                Menu {
                    ForEach([100, 75, 50, 25], id: \.self) { percent in
                        Button("\(percent) %") { editor.changeStyle { $0.opacity = Double(percent) / 100 } }
                    }
                } label: {
                    Label("\(Int((style.opacity * 100).rounded())) %", systemImage: "circle.lefthalf.filled")
                }
                .fixedSize()
                .help("Opacity")
            }
        }
    }
}

extension RGBA {
    init(cgColor: CGColor) {
        let srgb = cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let c = srgb?.components ?? [0, 0, 0, 1]
        if c.count >= 4 { self.init(c[0], c[1], c[2], c[3]) } else { self.init(c[0], c[0], c[0], c.count > 1 ? c[1] : 1) }
    }
}

// MARK: Side panel

/// The panel on the right while editing: light and colour, layers, history.
struct EditorSidebar: View {
    @ObservedObject var editor: PictureEditor

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $editor.panel) {
                ForEach(PictureEditor.Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch editor.panel {
            case .adjust: AdjustPanel(editor: editor)
            case .layers: LayersPanel(editor: editor)
            case .history: HistoryPanel(editor: editor)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

private struct AdjustPanel: View {
    @ObservedObject var editor: PictureEditor

    private let sliders: [(String, WritableKeyPath<Adjustments, Double>, ClosedRange<Double>)] = [
        ("Exposure", \.exposure, -1...1), ("Brightness", \.brightness, -1...1), ("Contrast", \.contrast, -1...1),
        ("Highlights", \.highlights, -1...1), ("Shadows", \.shadows, -1...1), ("Saturation", \.saturation, -1...1),
        ("Warmth", \.warmth, -1...1), ("Tint", \.tint, -1...1), ("Sharpness", \.sharpness, 0...1),
        ("Vignette", \.vignette, 0...1),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Auto Enhance", isOn: Binding(
                    get: { editor.document.adjustments.autoEnhance },
                    set: { on in editor.apply("Auto Enhance") { $0.adjustments.autoEnhance = on } }))
                ForEach(sliders, id: \.0) { name, path, range in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(name)
                            Spacer()
                            Text("\(Int((editor.document.adjustments[keyPath: path] * 100).rounded()))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { editor.document.adjustments[keyPath: path] },
                                              set: { value in editor.preview { $0.adjustments[keyPath: path] = value } }),
                               in: range) { editing in if !editing { editor.commit(name) } }
                    }
                    .onTapGesture(count: 2) { editor.apply(name) { $0.adjustments[keyPath: path] = 0 } }
                    .help("Double-click to reset")
                }
                Text("Filter").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 6) {
                    ForEach(Adjustments.Filter.allCases, id: \.self) { filter in
                        Button(filter.title) { editor.apply("Filter") { $0.adjustments.filter = filter } }
                            .buttonStyle(.bordered)
                            .tint(editor.document.adjustments.filter == filter ? .accentColor : nil)
                    }
                }
                Button("Reset Light and Colour") { editor.apply("Reset Light and Colour") { $0.adjustments = Adjustments() } }
                    .disabled(editor.document.adjustments.isIdentity)
            }
            .controlSize(.small)
            .padding(12)
        }
    }
}

private struct LayersPanel: View {
    @ObservedObject var editor: PictureEditor

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(editor.document.layers.reversed()) { layer in
                        LayerRow(editor: editor, layer: layer)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(layer.id == editor.currentLayer ? Color.accentColor.opacity(0.3) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { editor.currentLayer = layer.id }
                    }
                }
                .padding(8)
            }
            if let index = editor.document.layerIndex(editor.currentLayer) {
                let layer = editor.document.layers[index]
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Opacity")
                        Slider(value: Binding(get: { layer.opacity },
                                              set: { value in editor.preview { $0.layers[index].opacity = value } }),
                               in: 0...1) { editing in if !editing { editor.commit("Layer Opacity") } }
                        Text("\(Int((layer.opacity * 100).rounded())) %").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Picker("Blending", selection: Binding(get: { layer.blend },
                                                         set: { blend in editor.apply("Layer Blending") { $0.layers[index].blend = blend } })) {
                        ForEach(BlendMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button { editor.addLayer() } label: { Image(systemName: "plus") }.help("New Layer")
                        Button { editor.removeLayer(layer.id) } label: { Image(systemName: "minus") }.help("Delete Layer")
                        Spacer()
                        Button { editor.moveLayer(layer.id, by: 1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == editor.document.layers.count - 1).help("Move Up")
                        Button { editor.moveLayer(layer.id, by: -1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == 0).help("Move Down")
                        Button("Merge Down") { editor.mergeDown(layer.id) }.disabled(index == 0)
                    }
                    Text("New shapes go on the selected layer. Selected shapes can be moved to another layer from their right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .controlSize(.small)
                .padding(12)
            }
        }
    }
}

private struct LayerRow: View {
    @ObservedObject var editor: PictureEditor
    let layer: Layer
    @State private var name = ""

    var body: some View {
        HStack {
            Button {
                if let index = editor.document.layerIndex(layer.id) {
                    editor.apply(layer.isVisible ? "Hide Layer" : "Show Layer") { $0.layers[index].isVisible.toggle() }
                }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, let index = editor.document.layerIndex(layer.id) else { name = layer.name; return }
                    editor.apply("Rename Layer") { $0.layers[index].name = trimmed }
                }
            Spacer()
            Text("\(layer.shapes.count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .onAppear { name = layer.name }
        .onChange(of: layer.name) { name = $0 }
    }
}

private struct HistoryPanel: View {
    @ObservedObject var editor: PictureEditor

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                ForEach(Array(editor.history.steps.enumerated()), id: \.offset) { index, step in
                    Button { editor.jump(to: index) } label: {
                        HStack {
                            Text(step.name)
                                .fontWeight(index == editor.history.index ? .semibold : .regular)
                                .foregroundStyle(index > editor.history.index ? .secondary : .primary)
                            Spacer()
                            if index == editor.history.index { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(index == editor.history.index ? Color.accentColor.opacity(0.2) : .clear)
                    .id(index)
                }
                }
                .padding(.vertical, 6)
            }
            .onAppear { proxy.scrollTo(editor.history.index) }
            .onChange(of: editor.history.index) { proxy.scrollTo($0) }
        }
    }
}
