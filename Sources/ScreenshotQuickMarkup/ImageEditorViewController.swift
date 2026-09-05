@preconcurrency import AppKit

final class ImageEditorViewController: NSViewController {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onDone: (() -> Void)?
    var onOpenImage: ((NSImage) -> Void)?

    private let image: NSImage
    private let canvasView: MarkupCanvasView
    private let scrollView = NSScrollView()
    private let toolButtons = NSStackView()
    private let colorSwatches = NSStackView()
    private var swatchButtons: [ColorSwatchButton] = []
    private let colorWell = NSColorWell()
    private let colorControls = NSStackView()
    private let widthControls = NSStackView()
    private let fontControls = NSStackView()
    private let widthLabel = NSTextField(labelWithString: "Size")
    private let widthValueLabel = NSTextField(labelWithString: "4")
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 24, target: nil, action: nil)
    private let fontSizeSlider = NSSlider(value: 28, minValue: 12, maxValue: 96, target: nil, action: nil)
    private let fontSizeValueLabel = NSTextField(labelWithString: "28 pt")
    private let inspectorTitleLabel = NSTextField(labelWithString: "Pen")
    private let inspectorContextLabel = NSTextField(labelWithString: "TOOL")
    private let instructionsLabel = NSTextField(wrappingLabelWithString: "")
    private let selectionHintLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var isSynchronizingInspector = false

    private lazy var undoButton = iconButton(
        symbolName: "arrow.uturn.backward",
        action: #selector(undoTapped),
        tooltip: "Undo (⌘Z)"
    )
    private lazy var redoButton = iconButton(
        symbolName: "arrow.uturn.forward",
        action: #selector(redoTapped),
        tooltip: "Redo (⌘⇧Z)"
    )
    private lazy var editTextButton = actionButton(
        title: "Edit Text",
        symbolName: "character.cursor.ibeam",
        action: #selector(editTextTapped)
    )
    private lazy var deleteButton = actionButton(
        title: "Delete",
        symbolName: "trash",
        action: #selector(deleteTapped)
    )
    private lazy var copyButton = headerButton(
        title: "Copy",
        symbolName: "doc.on.doc",
        action: #selector(copyTapped),
        width: 76
    )
    private lazy var saveButton = headerButton(
        title: "Save",
        symbolName: "square.and.arrow.down",
        action: #selector(saveTapped),
        width: 76
    )
    private lazy var doneButton: NSButton = {
        let button = primaryHeaderButton(
            title: "Copy & Close",
            symbolName: "checkmark",
            action: #selector(doneTapped),
            width: 132
        )
        button.toolTip = "Copy edited image and close window"
        return button
    }()

    init(image: NSImage) {
        self.image = image
        canvasView = MarkupCanvasView(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        let header = makeSurface(material: .headerView)
        let toolRail = makeSurface(material: .sidebar)
        let inspector = makeSurface(material: .sidebar)
        let footer = makeSurface(material: .headerView)

        let titleLabel = NSTextField(labelWithString: "Screenshot")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        let dimensions = nativePixelDimensions
        let dimensionsLabel = NSTextField(
            labelWithString: "\(dimensions.width) × \(dimensions.height) px"
        )
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimensionsLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, dimensionsLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1

        let openButton = headerButton(
            title: "Open",
            symbolName: "folder",
            action: #selector(openTapped),
            width: 76
        )
        let headerRow = NSStackView(views: [
            titleStack, openButton, flexibleSpacer(), undoButton, redoButton,
            copyButton, saveButton, doneButton
        ])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)

        toolButtons.orientation = .vertical
        toolButtons.alignment = .centerX
        toolButtons.spacing = 3
        toolButtons.translatesAutoresizingMaskIntoConstraints = false
        for tool in MarkupTool.allCases {
            let button = ToolButton(tool: tool)
            button.target = self
            button.action = #selector(selectTool(_:))
            button.toolTip = "\(tool.title) (\(tool.shortcut))"
            toolButtons.addArrangedSubview(button)
        }
        let railStack = NSStackView(views: [toolButtons, flexibleVerticalSpacer()])
        railStack.orientation = .vertical
        railStack.alignment = .centerX
        railStack.spacing = 0
        railStack.translatesAutoresizingMaskIntoConstraints = false
        toolRail.addSubview(railStack)

        configureInspector()
        let inspectorStack = makeInspectorStack()
        inspector.addSubview(inspectorStack)

        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        configureFooter(in: footer)

        for child in [header, toolRail, scrollView, inspector, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            headerRow.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            toolRail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolRail.topAnchor.constraint(equalTo: header.bottomAnchor),
            toolRail.bottomAnchor.constraint(equalTo: footer.topAnchor),
            toolRail.widthAnchor.constraint(equalToConstant: 52),
            railStack.leadingAnchor.constraint(equalTo: toolRail.leadingAnchor),
            railStack.trailingAnchor.constraint(equalTo: toolRail.trailingAnchor),
            railStack.topAnchor.constraint(equalTo: toolRail.topAnchor, constant: 8),
            railStack.bottomAnchor.constraint(equalTo: toolRail.bottomAnchor, constant: -8),

            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: header.bottomAnchor),
            inspector.bottomAnchor.constraint(equalTo: footer.topAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 208),
            inspectorStack.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 14),
            inspectorStack.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -14),
            inspectorStack.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 16),
            inspectorStack.bottomAnchor.constraint(lessThanOrEqualTo: inspector.bottomAnchor, constant: -14),

            scrollView.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 36)
        ])

        view = root
        connectCanvasCallbacks()
        styleChanged()
        setTool(EditorPreferences.tool, focusCanvas: false)
        updateHistoryControls(canUndo: false, canRedo: false)
        updateInspector()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvasView.updateCanvasSize(scrollView.contentView.bounds.size)
    }

    func undo() { canvasView.undo() }
    func redo() { canvasView.redo() }
    func renderedPNGData() -> Data? { canvasView.renderedPNGData() }
    func renderedPNGDataAsync() async -> Data? { await canvasView.renderedPNGDataAsync() }

    func focusCanvas() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(canvasView)
    }

    func activateTool(_ tool: MarkupTool) {
        loadViewIfNeeded()
        setTool(tool)
    }

    func setExporting(_ exporting: Bool) {
        loadViewIfNeeded()
        copyButton.isEnabled = !exporting
        saveButton.isEnabled = !exporting
        doneButton.isEnabled = !exporting
        canvasView.isEditingEnabled = !exporting
        if exporting {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clearStatus), object: nil)
            statusLabel.stringValue = "Preparing image…"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.toolTip = nil
        }
    }

    func showStatus(_ message: String, isError: Bool = false) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clearStatus), object: nil)
        statusLabel.stringValue = message
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        statusLabel.toolTip = message
        perform(#selector(clearStatus), with: nil, afterDelay: isError ? 5 : 2.5)
    }

    private func configureInspector() {
        inspectorContextLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        inspectorContextLabel.textColor = .secondaryLabelColor
        inspectorTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        inspectorTitleLabel.textColor = .labelColor
        inspectorTitleLabel.lineBreakMode = .byTruncatingTail
        instructionsLabel.font = .systemFont(ofSize: 11)
        instructionsLabel.textColor = .secondaryLabelColor
        instructionsLabel.maximumNumberOfLines = 3
        instructionsLabel.lineBreakMode = .byWordWrapping
        selectionHintLabel.font = .systemFont(ofSize: 10)
        selectionHintLabel.textColor = .secondaryLabelColor
        selectionHintLabel.maximumNumberOfLines = 2

        colorSwatches.orientation = .vertical
        colorSwatches.alignment = .leading
        colorSwatches.spacing = 5
        let colors: [(String, NSColor)] = [
            ("Red", .systemRed), ("Yellow", .systemYellow), ("Green", .systemGreen),
            ("Blue", .systemBlue), ("Purple", .systemPurple), ("White", .white), ("Black", .black)
        ]
        for (name, color) in colors {
            let swatch = ColorSwatchButton(name: name, color: color)
            swatch.target = self
            swatch.action = #selector(selectSwatch(_:))
            swatchButtons.append(swatch)
        }
        let firstSwatchRow = NSStackView(views: Array(swatchButtons.prefix(4)))
        firstSwatchRow.orientation = .horizontal
        firstSwatchRow.spacing = 5
        let secondSwatchRow = NSStackView(views: Array(swatchButtons.dropFirst(4)))
        secondSwatchRow.orientation = .horizontal
        secondSwatchRow.spacing = 5
        secondSwatchRow.widthAnchor.constraint(equalToConstant: 64).isActive = true
        colorSwatches.addArrangedSubview(firstSwatchRow)
        colorSwatches.addArrangedSubview(secondSwatchRow)

        colorWell.color = EditorPreferences.color
        colorWell.target = self
        colorWell.action = #selector(styleChanged)
        colorWell.toolTip = "Custom color"
        colorWell.setAccessibilityLabel("Custom annotation color")
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 30).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let colorRow = NSStackView(views: [colorSwatches, flexibleSpacer(), colorWell])
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 6
        configureInspectorSection(colorControls, title: "COLOR", content: colorRow)

        configureValueLabel(widthValueLabel)
        widthSlider.doubleValue = Double(EditorPreferences.width)
        widthSlider.target = self
        widthSlider.action = #selector(styleChanged)
        widthSlider.isContinuous = false
        widthSlider.toolTip = "Stroke width or effect strength"
        widthSlider.setAccessibilityLabel("Annotation size")
        configureSliderSection(widthControls, titleLabel: widthLabel, slider: widthSlider, valueLabel: widthValueLabel)

        configureValueLabel(fontSizeValueLabel)
        fontSizeSlider.doubleValue = Double(EditorPreferences.fontSize)
        fontSizeSlider.target = self
        fontSizeSlider.action = #selector(styleChanged)
        fontSizeSlider.isContinuous = false
        fontSizeSlider.toolTip = "Text size"
        fontSizeSlider.setAccessibilityLabel("Text size")
        configureSliderSection(fontControls, titleLabel: sectionLabel("TEXT SIZE"), slider: fontSizeSlider, valueLabel: fontSizeValueLabel)
    }

    private func makeInspectorStack() -> NSStackView {
        let divider = separator()
        let actionRow = NSStackView(views: [editTextButton, deleteButton])
        actionRow.orientation = .horizontal
        actionRow.distribution = .fillEqually
        actionRow.spacing = 6
        let stack = NSStackView(views: [
            inspectorContextLabel, inspectorTitleLabel, instructionsLabel, selectionHintLabel,
            divider, colorControls, widthControls, fontControls, actionRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(2, after: inspectorContextLabel)
        stack.setCustomSpacing(7, after: inspectorTitleLabel)
        stack.setCustomSpacing(14, after: divider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for section in [colorControls, widthControls, fontControls] {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func configureFooter(in footer: NSView) {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setAccessibilityLabel("Editor status")
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = .secondaryLabelColor
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let zoomOut = iconButton(symbolName: "minus", action: #selector(zoomOutTapped), tooltip: "Zoom out")
        let fit = footerButton(title: "Fit", action: #selector(fitTapped), tooltip: "Fit to window")
        let actual = footerButton(title: "1:1", action: #selector(actualSizeTapped), tooltip: "Actual size")
        let zoomIn = iconButton(symbolName: "plus", action: #selector(zoomInTapped), tooltip: "Zoom in")
        for button in [zoomOut, zoomIn] {
            button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let footerRow = NSStackView(views: [statusLabel, flexibleSpacer(), zoomOut, zoomLabel, zoomIn, actual, fit])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 5
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerRow)
        NSLayoutConstraint.activate([
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            footerRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            footerRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    private func connectCanvasCallbacks() {
        canvasView.onHistoryChanged = { [weak self] canUndo, canRedo in
            self?.updateHistoryControls(canUndo: canUndo, canRedo: canRedo)
        }
        canvasView.onSelectionChanged = { [weak self] _ in
            self?.updateInspector(syncFromSelection: true)
        }
        canvasView.onToolShortcut = { [weak self] tool in self?.setTool(tool) }
        canvasView.onZoomChanged = { [weak self] percentage in self?.zoomLabel.stringValue = "\(percentage)%" }
        canvasView.onImageDropped = { [weak self] image in self?.onOpenImage?(image) }
        zoomLabel.stringValue = "\(canvasView.zoomPercentage)%"
    }

    @objc private func selectTool(_ sender: ToolButton) { setTool(sender.tool) }

    @objc private func styleChanged() {
        guard !isSynchronizingInspector else { return }
        let color = colorWell.color
        let width = CGFloat(widthSlider.doubleValue)
        let fontSize = CGFloat(fontSizeSlider.doubleValue)
        canvasView.currentColor = color
        canvasView.currentWidth = width
        canvasView.currentFontSize = fontSize
        EditorPreferences.color = color
        EditorPreferences.width = width
        EditorPreferences.fontSize = fontSize
        updateStyleLabels()
        updateSelectedColorSwatches()
        if canvasView.selectedAnnotation != nil {
            canvasView.updateSelectedStyle(color: color, width: width, fontSize: fontSize)
        }
    }

    @objc private func selectSwatch(_ sender: ColorSwatchButton) {
        colorWell.color = sender.color
        styleChanged()
    }

    @objc private func openTapped() {
        guard let image = ImageImport.chooseImage() else {
            focusCanvas()
            return
        }
        onOpenImage?(image)
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func saveTapped() { onSave?() }
    @objc private func doneTapped() { onDone?() }
    @objc private func undoTapped() { undo() }
    @objc private func redoTapped() { redo() }
    @objc private func deleteTapped() { canvasView.deleteSelectedAnnotation() }
    @objc private func editTextTapped() { canvasView.editSelectedText() }
    @objc private func zoomOutTapped() { canvasView.zoomOut(in: scrollView.contentView.bounds.size) }
    @objc private func actualSizeTapped() { canvasView.zoomActualSize(in: scrollView.contentView.bounds.size) }
    @objc private func fitTapped() { canvasView.zoomToFit(in: scrollView.contentView.bounds.size) }
    @objc private func zoomInTapped() { canvasView.zoomIn(in: scrollView.contentView.bounds.size) }

    @objc private func clearStatus() {
        statusLabel.stringValue = "Ready"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
    }

    private func setTool(_ tool: MarkupTool, focusCanvas: Bool = true) {
        guard canvasView.isEditingEnabled else { return }
        canvasView.tool = tool
        EditorPreferences.tool = tool
        if tool != .select {
            colorWell.color = EditorPreferences.color
            widthSlider.doubleValue = Double(EditorPreferences.width)
            fontSizeSlider.doubleValue = Double(EditorPreferences.fontSize)
            styleChanged()
        }
        updateSelectedToolButtons()
        updateInspector(syncFromSelection: tool == .select)
        if focusCanvas { view.window?.makeFirstResponder(canvasView) }
    }

    private func updateInspector(syncFromSelection: Bool = false) {
        let selection = canvasView.selectedAnnotation
        let displayedTool = canvasView.tool == .select ? selection?.tool : canvasView.tool
        if syncFromSelection, let selection {
            isSynchronizingInspector = true
            if let color = selection.color { colorWell.color = color }
            if let width = selection.editableWidth { widthSlider.doubleValue = Double(width) }
            if let fontSize = selection.fontSize { fontSizeSlider.doubleValue = Double(fontSize) }
            isSynchronizingInspector = false
        }

        inspectorContextLabel.stringValue = canvasView.tool == .select ? "SELECTION" : "TOOL"
        inspectorTitleLabel.stringValue = displayedTool?.title ?? "No Selection"
        instructionsLabel.stringValue = inspectorInstructions(for: displayedTool)
        if canvasView.tool == .select {
            if let selection {
                selectionHintLabel.stringValue = selection.canResize
                    ? "Drag to move. Drag handles to resize."
                    : "Drag to move. Arrow keys nudge."
            } else {
                selectionHintLabel.stringValue = "Choose an annotation on the canvas."
            }
        } else {
            selectionHintLabel.stringValue = "Shortcut: \(canvasView.tool.shortcut)"
        }

        let hasSelection = selection != nil
        let usesColor = canvasView.tool == .select
            ? selection?.color != nil
            : displayedTool.map(toolUsesColor) ?? false
        let usesWidth = canvasView.tool == .select
            ? selection?.editableWidth != nil
            : displayedTool.map(toolUsesWidth) ?? false
        let usesFontSize = canvasView.tool == .select
            ? selection?.fontSize != nil
            : displayedTool == .text
        colorControls.isHidden = !usesColor
        widthControls.isHidden = !usesWidth
        fontControls.isHidden = !usesFontSize
        editTextButton.isHidden = selection?.tool != .text
        deleteButton.isHidden = !hasSelection
        editTextButton.isEnabled = selection?.tool == .text
        deleteButton.isEnabled = hasSelection
        updateStyleLabels()
        updateSelectedColorSwatches()
    }

    private func inspectorInstructions(for tool: MarkupTool?) -> String {
        guard let tool else { return "Select an annotation to adjust its style or remove it." }
        switch tool {
        case .select: return "Click an annotation, then drag it to reposition."
        case .pen: return "Draw freehand lines directly on the screenshot."
        case .highlighter: return "Drag across content to add translucent emphasis."
        case .arrow: return "Drag from the tail toward the point of interest."
        case .rectangle: return "Drag to frame an area with a crisp outline."
        case .ellipse: return "Drag to circle a detail or region."
        case .mosaic: return "Pixelate an area. Use Redact for opaque coverage."
        case .redaction: return "Drag over sensitive content to cover it completely."
        case .marker: return "Click to place the next numbered marker."
        case .check: return "Click to place a confirmation mark."
        case .text: return "Click the canvas to add text. Double-click text to edit."
        }
    }

    private func toolUsesColor(_ tool: MarkupTool) -> Bool {
        switch tool {
        case .select, .mosaic, .redaction: return false
        case .pen, .highlighter, .arrow, .rectangle, .ellipse, .marker, .check, .text: return true
        }
    }

    private func toolUsesWidth(_ tool: MarkupTool) -> Bool {
        switch tool {
        case .pen, .highlighter, .arrow, .rectangle, .ellipse, .mosaic: return true
        case .select, .redaction, .marker, .check, .text: return false
        }
    }

    private func updateSelectedToolButtons() {
        for case let button as ToolButton in toolButtons.arrangedSubviews {
            button.isSelectedTool = button.tool == canvasView.tool
        }
    }

    private func updateStyleLabels() {
        let displayedTool = canvasView.tool == .select ? canvasView.selectedAnnotation?.tool : canvasView.tool
        widthLabel.stringValue = displayedTool == .mosaic ? "BLUR STRENGTH" : "SIZE"
        widthValueLabel.stringValue = "\(Int(widthSlider.doubleValue.rounded()))"
        fontSizeValueLabel.stringValue = "\(Int(fontSizeSlider.doubleValue.rounded())) pt"
    }

    private func updateHistoryControls(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    private func updateSelectedColorSwatches() {
        for swatch in swatchButtons {
            swatch.isSelectedColor = swatch.color.isEqual(colorWell.color)
        }
    }

    private func configureInspectorSection(_ stack: NSStackView, title: String, content: NSView) {
        let label = sectionLabel(title)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSliderSection(
        _ stack: NSStackView,
        titleLabel: NSTextField,
        slider: NSSlider,
        valueLabel: NSTextField
    ) {
        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [titleLabel, flexibleSpacer(), valueLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        let body = NSStackView(views: [heading, slider])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 5
        heading.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        slider.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureValueLabel(_ label: NSTextField) {
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
    }

    private func makeSurface(material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let surface = NSVisualEffectView()
        surface.material = material
        surface.blendingMode = .withinWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.borderColor = NSColor.separatorColor.cgColor
        surface.layer?.borderWidth = 0.5
        return surface
    }

    private var nativePixelDimensions: (width: Int, height: Int) {
        let representationWidth = image.representations.map(\.pixelsWide).filter { $0 > 0 }.max()
        let representationHeight = image.representations.map(\.pixelsHigh).filter { $0 > 0 }.max()
        return (
            representationWidth ?? max(1, Int(image.size.width.rounded())),
            representationHeight ?? max(1, Int(image.size.height.rounded()))
        )
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func headerButton(title: String, symbolName: String, action: Selector, width: CGFloat) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    private func primaryHeaderButton(
        title: String,
        symbolName: String,
        action: Selector,
        width: CGFloat
    ) -> NSButton {
        let button = PrimaryActionButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.controlSize = .regular
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        button.font = font
        button.contentTintColor = .white
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: titleAttributes)
        button.attributedAlternateTitle = button.attributedTitle
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    private func iconButton(symbolName: String, action: Selector, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return button
    }

    private func actionButton(title: String, symbolName: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func footerButton(title: String, action: Selector, tooltip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func flexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func flexibleVerticalSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return spacer
    }
}

private final class PrimaryActionButton: NSButton {
    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.5
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let fillAlpha: CGFloat = isHighlighted ? 0.78 : 1
        NSColor.controlAccentColor.withAlphaComponent(fillAlpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class ToolButton: NSButton {
    let tool: MarkupTool

    var isSelectedTool = false {
        didSet {
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.backgroundColor = isSelectedTool
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
            contentTintColor = isSelectedTool ? .controlAccentColor : .secondaryLabelColor
            state = isSelectedTool ? .on : .off
            setAccessibilityValue(isSelectedTool ? "Selected" : "Not selected")
        }
    }

    init(tool: MarkupTool) {
        self.tool = tool
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: tool.title)
        imagePosition = .imageOnly
        bezelStyle = .rounded
        isBordered = false
        title = ""
        setButtonType(.toggle)
        setAccessibilityLabel("\(tool.title) tool")
        setAccessibilityHelp("Keyboard shortcut \(tool.shortcut)")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class ColorSwatchButton: NSButton {
    let color: NSColor

    var isSelectedColor = false {
        didSet {
            layer?.borderWidth = isSelectedColor ? 2.5 : 1
            layer?.borderColor = isSelectedColor
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            state = isSelectedColor ? .on : .off
            setAccessibilityValue(isSelectedColor ? "Selected" : "Not selected")
        }
    }

    init(name: String, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.toggle)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = color.cgColor
        toolTip = "Use \(name.lowercased())"
        setAccessibilityLabel("\(name) annotation color")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
