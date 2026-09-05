@preconcurrency import AppKit
import ScreenshotQuickMarkupCore

private enum ZoomMode {
    case fit
    case fixed(CGFloat)
}

final class MarkupCanvasView: NSView, NSTextFieldDelegate {
    var onHistoryChanged: ((Bool, Bool) -> Void)?
    var onSelectionChanged: ((Bool) -> Void)?
    var onToolShortcut: ((MarkupTool) -> Void)?
    var onZoomChanged: ((Int) -> Void)?
    var onImageDropped: ((NSImage) -> Void)?
    var isEditingEnabled = true {
        didSet { if !isEditingEnabled { settleEditing() } }
    }

    var selectedAnnotation: Annotation? {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return nil }
        return annotations[index]
    }
    var zoomPercentage: Int { Int((previewScale * 100).rounded()) }
    private(set) var lastDrawnAnnotationCount = 0

    let image: NSImage
    var tool: MarkupTool = .pen {
        didSet {
            guard isEditingEnabled else { tool = oldValue; return }
            guard tool != oldValue else { return }
            if selectionDragOriginalState != nil { cancelSelectionGesture() }
            cancelInProgressAnnotation()
            if tool != .text {
                commitActiveText()
            }
            if tool != .select {
                setSelectedAnnotation(nil)
            }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var currentColor: NSColor = .systemRed
    var currentWidth: CGFloat = 4
    var currentFontSize: CGFloat = 28

    private var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var currentStrokePoints: [NSPoint] = []
    private var currentShapeStart: NSPoint?
    private var currentShapeEnd: NSPoint?
    private var activeTextField: NSTextField?
    private var activeTextOrigin: NSPoint?
    private var activeTextAnnotationIndex: Int?
    private var activeTextOriginal: Annotation?
    private var activeTextColor: NSColor = .systemRed
    private var activeTextFontSize: CGFloat = 28
    private var selectedAnnotationIndex: Int?
    private var selectionDragStart: NSPoint?
    private var selectionDragOriginalAnnotation: Annotation?
    private var selectionDragOriginalState: [Annotation]?
    private var selectionDidMove = false
    private var selectionResizeHandle: Int?
    private var previewScale: CGFloat = 1
    private var zoomMode: ZoomMode = .fit
    private var lastContainerSize = NSSize(width: 980, height: 654)
    private let renderer: AnnotationRenderer
    private var annotationBoundsCache: [Int: NSRect] = [:]
    private var cachedPNG: (revision: UInt64, data: Data)?
    private var contentRevision: UInt64 = 0

    override var isFlipped: Bool { true }

    init(image: NSImage) {
        self.image = image
        renderer = AnnotationRenderer(image: image)
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        registerForDraggedTypes([.fileURL, .png, .tiff])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screenshot markup canvas")
        setAccessibilityHelp("Use tool shortcuts to annotate. Select an annotation to move or delete it.")
        applyCanvasSize()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: .openHand
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(imageRect, cursor: cursor)
    }

    func updateCanvasSize(_ containerSize: NSSize) {
        guard containerSize != lastContainerSize else { return }
        settleEditing()
        lastContainerSize = containerSize
        applyCanvasSize()
    }

    func zoomIn(in containerSize: NSSize) {
        lastContainerSize = containerSize
        setZoomScale(previewScale * 1.25)
    }

    func zoomOut(in containerSize: NSSize) {
        lastContainerSize = containerSize
        setZoomScale(previewScale / 1.25)
    }

    func zoomActualSize(in containerSize: NSSize) {
        lastContainerSize = containerSize
        setZoomScale(1)
    }

    func zoomToFit(in containerSize: NSSize) {
        settleEditing()
        lastContainerSize = containerSize
        zoomMode = .fit
        applyCanvasSize()
    }

    private func setZoomScale(_ scale: CGFloat) {
        settleEditing()
        zoomMode = .fixed(min(6, max(0.1, scale)))
        applyCanvasSize()
    }

    private func applyCanvasSize() {
        let imageSize = image.size
        switch zoomMode {
        case .fit:
            previewScale = MarkupGeometry.previewScale(for: imageSize, viewportSize: lastContainerSize)
        case let .fixed(scale):
            previewScale = scale
        }
        let size = NSSize(
            width: max(imageSize.width * previewScale + 80, lastContainerSize.width),
            height: max(imageSize.height * previewScale + 80, lastContainerSize.height)
        )
        setFrameSize(size)
        annotationBoundsCache.removeAll(keepingCapacity: true)
        onZoomChanged?(zoomPercentage)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        }
        contentDidChange()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()

        let rect = imageRect
        image.draw(in: rect)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let transform = imageTransform
        lastDrawnAnnotationCount = 0
        for index in annotations.indices where !annotations[index].isRedaction {
            drawAnnotation(at: index, dirtyRect: dirtyRect, transform: transform)
        }
        drawInProgress(transform: transform)
        // Redaction stays above source-based effects, including an in-progress blur.
        for index in annotations.indices where annotations[index].isRedaction {
            drawAnnotation(at: index, dirtyRect: dirtyRect, transform: transform)
        }
        NSGraphicsContext.restoreGraphicsState()
        drawSelectionOverlay(transform: transform)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditingEnabled else { return }
        commitActiveText()
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if tool == .select, let selected = selectedAnnotation,
           let handle = selected.resizeHandles.firstIndex(where: {
               let center = imageTransform($0)
               return hypot(center.x - viewPoint.x, center.y - viewPoint.y) <= 8
           }) {
            beginSelectionResize(handle: handle, at: viewPoint)
            return
        }
        guard let point = imagePoint(from: viewPoint) else { return }

        if event.clickCount >= 2, let index = annotationIndex(at: point), annotations[index].tool == .text {
            tool = .select
            setSelectedAnnotation(index)
            onToolShortcut?(.select)
            editSelectedText()
            return
        }

        if tool == .select {
            beginSelection(at: point)
            if event.clickCount >= 2 { editSelectedText() }
            return
        }

        if event.clickCount >= 2 || tool == .text {
            beginTextEditing(at: point)
            return
        }

        switch tool {
        case .pen, .highlighter:
            currentStrokePoints = [point]
        case .arrow, .rectangle, .ellipse, .redaction:
            currentShapeStart = point
            currentShapeEnd = point
        case .mosaic:
            currentShapeStart = point
            currentShapeEnd = point
        case .marker:
            append(.marker(number: nextMarkerNumber(), center: point, color: currentColor))
        case .check:
            append(.checkmark(center: point, color: currentColor))
        case .select, .text:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditingEnabled else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if tool == .select, selectionResizeHandle != nil {
            resizeSelection(to: viewPoint)
            return
        }
        guard let point = imagePoint(from: viewPoint) else { return }
        switch tool {
        case .pen, .highlighter:
            let minimumDistance = max(0.75, currentWidth * 0.15)
            if let last = currentStrokePoints.last,
               hypot(point.x - last.x, point.y - last.y) < minimumDistance {
                return
            }
            let previous = currentStrokePoints.last ?? point
            currentStrokePoints.append(point)
            let width = currentWidth * (tool == .highlighter ? 2.8 : 1) * displayScale
            let changed = MarkupGeometry.normalizedRect(from: imageTransform(previous), to: imageTransform(point))
                .insetBy(dx: -width - 3, dy: -width - 3)
            setNeedsDisplay(changed)
        case .arrow, .rectangle, .ellipse, .mosaic, .redaction:
            let previous = inProgressAnnotation
            currentShapeEnd = point
            invalidate(previous)
            invalidate(inProgressAnnotation)
        case .select:
            moveSelection(to: point)
        case .marker, .check, .text:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditingEnabled else { return }
        if tool == .select {
            finishSelectionMove()
            return
        }
        finishDrawing()
    }

    private func finishDrawing() {
        guard !currentStrokePoints.isEmpty || currentShapeStart != nil else { return }
        defer {
            currentStrokePoints = []
            currentShapeStart = nil
            currentShapeEnd = nil
            needsDisplay = true
        }

        switch tool {
        case .pen:
            guard currentStrokePoints.count > 1 else { return }
            append(.stroke(points: currentStrokePoints, color: currentColor, width: currentWidth, alpha: 1))
        case .highlighter:
            guard currentStrokePoints.count > 1 else { return }
            append(.stroke(points: currentStrokePoints, color: currentColor, width: currentWidth * 2.8, alpha: 0.32))
        case .arrow:
            appendCurrentShape(.arrow)
        case .rectangle:
            appendCurrentShape(.rectangle)
        case .ellipse:
            appendCurrentShape(.ellipse)
        case .mosaic:
            appendCurrentMosaic()
        case .redaction:
            guard let start = currentShapeStart, let end = currentShapeEnd,
                  abs(end.x - start.x) >= 4, abs(end.y - start.y) >= 4 else { return }
            append(.redaction(start: start, end: end))
        case .select, .marker, .check, .text:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        guard isEditingEnabled else { return }
        let keyCode = Int(event.keyCode)
        switch keyCode {
        case 51, 117:
            deleteSelectedAnnotation()
            return
        case 53:
            if activeTextField != nil {
                cancelActiveText()
            } else if selectionDragOriginalState != nil {
                cancelSelectionGesture()
            } else if selectedAnnotationIndex != nil {
                setSelectedAnnotation(nil)
            } else {
                cancelInProgressAnnotation()
            }
            return
        case 123, 124, 125, 126:
            guard selectedAnnotationIndex != nil else { break }
            let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: NSSize = switch keyCode {
            case 123: NSSize(width: -distance, height: 0)
            case 124: NSSize(width: distance, height: 0)
            case 125: NSSize(width: 0, height: distance)
            default: NSSize(width: 0, height: -distance)
            }
            nudgeSelectedAnnotation(by: delta)
            return
        default:
            break
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           let character = event.charactersIgnoringModifiers?.uppercased(),
           let shortcutTool = MarkupTool.allCases.first(where: { $0.shortcut == character }) {
            onToolShortcut?(shortcutTool)
            return
        }

        super.keyDown(with: event)
    }

    func undo() {
        guard isEditingEnabled else { return }
        settleEditing()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        contentDidChange()
        annotationBoundsCache.removeAll(keepingCapacity: true)
        setSelectedAnnotation(nil)
        notifyHistoryChanged()
        needsDisplay = true
    }

    func redo() {
        guard isEditingEnabled else { return }
        settleEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        contentDidChange()
        annotationBoundsCache.removeAll(keepingCapacity: true)
        setSelectedAnnotation(nil)
        notifyHistoryChanged()
        needsDisplay = true
    }

    func deleteSelectedAnnotation() {
        guard isEditingEnabled else { return }
        settleEditing()
        guard let selectedAnnotationIndex, annotations.indices.contains(selectedAnnotationIndex) else { return }
        recordStateForUndo()
        annotations.remove(at: selectedAnnotationIndex)
        contentDidChange()
        annotationBoundsCache.removeAll(keepingCapacity: true)
        setSelectedAnnotation(nil)
        needsDisplay = true
    }

    func renderedPNGData() -> Data? {
        settleEditing()
        if let cachedPNG, cachedPNG.revision == contentRevision { return cachedPNG.data }
        var result: Data?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            result = renderer.renderedPNGData(annotations: annotations)
        }
        return result
    }

    func renderedPNGDataAsync() async -> Data? {
        settleEditing()
        if let cachedPNG, cachedPNG.revision == contentRevision { return cachedPNG.data }
        let revision = contentRevision
        var snapshot: CGImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            snapshot = renderer.renderedCGImage(annotations: annotations)
        }
        guard let image = snapshot else { return nil }
        guard let data = await PNGEncoder.encode(image), !Task.isCancelled else { return nil }
        if revision == contentRevision { cachedPNG = (revision, data) }
        return data
    }

    private var imageRect: NSRect {
        let imageSize = image.size
        let scale = max(0.1, previewScale)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var imageTransform: (NSPoint) -> NSPoint {
        let rect = imageRect
        let scaleX = rect.width / max(image.size.width, 1)
        let scaleY = rect.height / max(image.size.height, 1)
        return { point in
            NSPoint(x: rect.minX + point.x * scaleX, y: rect.minY + point.y * scaleY)
        }
    }

    private func imagePoint(from viewPoint: NSPoint) -> NSPoint? {
        let rect = imageRect
        guard rect.contains(viewPoint) else { return nil }
        let scaleX = image.size.width / max(rect.width, 1)
        let scaleY = image.size.height / max(rect.height, 1)
        return NSPoint(
            x: (viewPoint.x - rect.minX) * scaleX,
            y: (viewPoint.y - rect.minY) * scaleY
        )
    }

    private func viewPoint(from imagePoint: NSPoint) -> NSPoint {
        imageTransform(imagePoint)
    }

    private func append(_ annotation: Annotation) {
        recordStateForUndo()
        annotations.append(annotation)
        contentDidChange()
        invalidate(annotation)
    }

    private func contentDidChange() {
        contentRevision &+= 1
        cachedPNG = nil
    }

    private func settleEditing() {
        commitActiveText()
        if selectionDragOriginalState != nil { finishSelectionMove() }
        finishDrawing()
    }

    private func screenBounds(of index: Int) -> NSRect {
        if let cached = annotationBoundsCache[index] { return cached }
        let rect = annotations[index].displayBounds(scale: displayScale, offset: imageRect.origin)
        annotationBoundsCache[index] = rect
        return rect
    }

    private func drawAnnotation(at index: Int, dirtyRect: NSRect, transform: (NSPoint) -> NSPoint) {
        guard index != activeTextAnnotationIndex, screenBounds(of: index).intersects(dirtyRect) else { return }
        draw(annotations[index], transform: transform)
        lastDrawnAnnotationCount += 1
    }

    private func invalidate(_ annotation: Annotation?) {
        guard let annotation else { return }
        setNeedsDisplay(annotation.displayBounds(scale: displayScale, offset: imageRect.origin).insetBy(dx: -10, dy: -10))
    }

    func updateSelectedStyle(color: NSColor, width: CGFloat, fontSize: CGFloat) {
        guard isEditingEnabled else { return }
        settleEditing()
        guard let selected = selectedAnnotation else { return }
        replaceSelection(with: selected.styled(color: color, width: min(24, max(1, width)), fontSize: min(96, max(12, fontSize))))
    }

    private func replaceSelection(with annotation: Annotation) {
        guard let index = selectedAnnotationIndex, let old = selectedAnnotation, old != annotation else { return }
        recordStateForUndo()
        annotations[index] = annotation
        annotationBoundsCache[index] = nil
        contentDidChange()
        invalidate(old)
        invalidate(annotation)
        onSelectionChanged?(true)
    }

    private func beginSelection(at point: NSPoint) {
        let hitIndex = annotationIndex(at: point)
        setSelectedAnnotation(hitIndex)
        guard let hitIndex else { return }
        selectionDragStart = point
        selectionDragOriginalAnnotation = annotations[hitIndex]
        selectionDragOriginalState = annotations
        selectionDidMove = false
        selectionResizeHandle = nil
    }

    private func annotationIndex(at point: NSPoint) -> Int? {
        let tolerance = 8 / max(previewScale, 0.1)
        let ordered = annotations.indices.filter { !annotations[$0].isRedaction }
            + annotations.indices.filter { annotations[$0].isRedaction }
        return ordered.reversed().first {
            annotations[$0].hitTest(point, tolerance: tolerance)
        }
    }

    private func beginSelectionResize(handle: Int, at point: NSPoint) {
        selectionResizeHandle = handle
        selectionDragStart = point
        selectionDragOriginalAnnotation = selectedAnnotation
        selectionDragOriginalState = annotations
        selectionDidMove = false
    }

    private func resizeSelection(to viewPoint: NSPoint) {
        guard let handle = selectionResizeHandle, let original = selectionDragOriginalAnnotation,
              let index = selectedAnnotationIndex else { return }
        let point = NSPoint(x: min(image.size.width, max(0, (viewPoint.x - imageRect.minX) / displayScale)),
                            y: min(image.size.height, max(0, (viewPoint.y - imageRect.minY) / displayScale)))
        let resized = original.resized(handle: handle, to: point)
        invalidate(annotations[index])
        annotations[index] = resized
        annotationBoundsCache[index] = nil
        contentDidChange()
        invalidate(resized)
        selectionDidMove = resized != original
    }

    private func moveSelection(to point: NSPoint) {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex),
              let dragStart = selectionDragStart,
              let original = selectionDragOriginalAnnotation
        else {
            return
        }

        let proposed = NSSize(width: point.x - dragStart.x, height: point.y - dragStart.y)
        let delta = clampedTranslation(for: original, proposed: proposed)
        invalidate(annotations[selectedAnnotationIndex])
        annotations[selectedAnnotationIndex] = original.translated(by: delta)
        annotationBoundsCache[selectedAnnotationIndex] = nil
        contentDidChange()
        invalidate(annotations[selectedAnnotationIndex])
        selectionDidMove = abs(delta.width) > 0.01 || abs(delta.height) > 0.01
        NSCursor.closedHand.set()
    }

    private func finishSelectionMove() {
        if selectionDidMove, let originalState = selectionDragOriginalState {
            pushUndoState(originalState)
        }
        selectionDragStart = nil
        selectionDragOriginalAnnotation = nil
        selectionDragOriginalState = nil
        selectionDidMove = false
        selectionResizeHandle = nil
        window?.invalidateCursorRects(for: self)
        invalidate(selectedAnnotation)
    }

    private func cancelSelectionGesture() {
        if let originalState = selectionDragOriginalState {
            annotations = originalState
            annotationBoundsCache.removeAll(keepingCapacity: true)
            contentDidChange()
        }
        selectionDidMove = false
        finishSelectionMove()
        needsDisplay = true
    }

    private func nudgeSelectedAnnotation(by proposed: NSSize) {
        settleEditing()
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex)
        else {
            return
        }
        let original = annotations[selectedAnnotationIndex]
        let delta = clampedTranslation(for: original, proposed: proposed)
        guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else { return }
        recordStateForUndo()
        annotations[selectedAnnotationIndex] = original.translated(by: delta)
        annotationBoundsCache[selectedAnnotationIndex] = nil
        contentDidChange()
        invalidate(original)
        invalidate(annotations[selectedAnnotationIndex])
    }

    private func clampedTranslation(for annotation: Annotation, proposed: NSSize) -> NSSize {
        let bounds = annotation.bounds
        return NSSize(
            width: MarkupGeometry.clampedTranslationDelta(
                minimum: bounds.minX,
                maximum: bounds.maxX,
                limit: image.size.width,
                proposed: proposed.width
            ),
            height: MarkupGeometry.clampedTranslationDelta(
                minimum: bounds.minY,
                maximum: bounds.maxY,
                limit: image.size.height,
                proposed: proposed.height
            )
        )
    }

    private func setSelectedAnnotation(_ index: Int?) {
        guard selectedAnnotationIndex != index else { return }
        invalidate(selectedAnnotation)
        selectedAnnotationIndex = index
        invalidate(selectedAnnotation)
        onSelectionChanged?(index != nil)
    }

    private func recordStateForUndo() {
        pushUndoState(annotations)
    }

    private func pushUndoState(_ state: [Annotation]) {
        undoStack.append(state)
        if undoStack.count > 100 {
            undoStack.removeFirst(undoStack.count - 100)
        }
        redoStack.removeAll()
        notifyHistoryChanged()
    }

    private func notifyHistoryChanged() {
        onHistoryChanged?(!undoStack.isEmpty, !redoStack.isEmpty)
    }

    private func cancelInProgressAnnotation() {
        currentStrokePoints.removeAll()
        currentShapeStart = nil
        currentShapeEnd = nil
        needsDisplay = true
    }

    private func nextMarkerNumber() -> Int {
        let maxNumber = annotations.compactMap { annotation -> Int? in
            if case let .marker(number, _, _) = annotation {
                return number
            }
            return nil
        }.max() ?? 0
        return maxNumber + 1
    }

    private func appendCurrentShape(_ kind: ShapeKind) {
        guard let start = currentShapeStart,
              let end = currentShapeEnd,
              hypot(end.x - start.x, end.y - start.y) >= 4
        else {
            return
        }
        append(.shape(kind: kind, start: start, end: end, color: currentColor, width: currentWidth))
    }

    private func appendCurrentMosaic() {
        guard let start = currentShapeStart,
              let end = currentShapeEnd,
              abs(end.x - start.x) >= 8,
              abs(end.y - start.y) >= 8
        else {
            return
        }
        append(.mosaic(start: start, end: end, strength: currentWidth))
    }

    func editSelectedText() {
        guard isEditingEnabled, let index = selectedAnnotationIndex,
              case let .text(text, origin, color, size, _) = annotations[index] else { return }
        beginTextEditing(at: origin, text: text, color: color, fontSize: size, annotationIndex: index)
    }

    private func beginTextEditing(
        at point: NSPoint, text: String = "", color: NSColor? = nil,
        fontSize: CGFloat? = nil, annotationIndex: Int? = nil
    ) {
        commitActiveText()
        selectionDidMove = false
        finishSelectionMove()
        activeTextColor = color ?? currentColor
        activeTextFontSize = fontSize ?? currentFontSize
        activeTextAnnotationIndex = annotationIndex
        activeTextOriginal = annotationIndex.map { annotations[$0] }
        invalidate(activeTextOriginal)
        let viewPoint = viewPoint(from: point)
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 260,
                                              height: max(activeTextFontSize * displayScale + 14, 38)))
        field.stringValue = text
        field.placeholderString = "Text"
        field.font = .systemFont(ofSize: activeTextFontSize * displayScale, weight: .semibold)
        field.textColor = activeTextColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        field.isBordered = true
        field.delegate = self
        field.target = self
        field.action = #selector(commitActiveText)
        addSubview(field)
        activeTextField = field
        activeTextOrigin = point
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.allowsUndo = true
            editor.breakUndoCoalescing()
        }
    }

    private func cancelActiveText() {
        let field = activeTextField
        invalidate(activeTextOriginal)
        activeTextField = nil
        activeTextOrigin = nil
        activeTextAnnotationIndex = nil
        activeTextOriginal = nil
        field?.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    @objc private func commitActiveText() {
        guard let field = activeTextField,
              let origin = activeTextOrigin
        else {
            return
        }

        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = activeTextAnnotationIndex
        let original = activeTextOriginal
        let background: Bool
        if let original, case let .text(_, _, _, _, existingBackground) = original {
            background = existingBackground
        } else {
            background = true
        }
        let updated = Annotation.text(text, origin: origin, color: activeTextColor,
                                      fontSize: activeTextFontSize, background: background)
        cancelActiveText()
        if let index, annotations.indices.contains(index), let original {
            guard updated != original else { return }
            recordStateForUndo()
            if text.isEmpty {
                annotations.remove(at: index)
                annotationBoundsCache.removeAll(keepingCapacity: true)
                setSelectedAnnotation(nil)
            } else {
                annotations[index] = updated
                annotationBoundsCache[index] = nil
                invalidate(updated)
                onSelectionChanged?(selectedAnnotationIndex != nil)
            }
            contentDidChange()
        } else if !text.isEmpty {
            append(updated)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitActiveText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelActiveText()
            return true
        }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditingEnabled,
              sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditingEnabled, let onImageDropped,
              let image = ImageImport.image(from: sender.draggingPasteboard) else { return false }
        onImageDropped(image)
        return true
    }

    private var inProgressAnnotation: Annotation? {
        switch tool {
        case .pen:
            return .stroke(points: currentStrokePoints, color: currentColor, width: currentWidth, alpha: 1)
        case .highlighter:
            return .stroke(points: currentStrokePoints, color: currentColor, width: currentWidth * 2.8, alpha: 0.32)
        case .arrow, .rectangle, .ellipse, .mosaic, .redaction:
            guard let start = currentShapeStart, let end = currentShapeEnd else { return nil }
            switch tool {
            case .mosaic: return .mosaic(start: start, end: end, strength: currentWidth)
            case .redaction: return .redaction(start: start, end: end)
            default:
                let kind: ShapeKind = tool == .arrow ? .arrow : (tool == .rectangle ? .rectangle : .ellipse)
                return .shape(kind: kind, start: start, end: end, color: currentColor, width: currentWidth)
            }
        default: return nil
        }
    }

    private func drawInProgress(transform: (NSPoint) -> NSPoint) {
        if let annotation = inProgressAnnotation { draw(annotation, transform: transform) }
    }

    private func drawSelectionOverlay(transform: (NSPoint) -> NSPoint) {
        guard let selectedAnnotationIndex,
              annotations.indices.contains(selectedAnnotationIndex)
        else {
            return
        }

        let annotation = annotations[selectedAnnotationIndex]
        let rect = screenBounds(of: selectedAnnotationIndex).insetBy(dx: -4, dy: -4)

        let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        outline.lineWidth = 3
        NSColor.white.withAlphaComponent(0.92).setStroke()
        outline.stroke()

        outline.lineWidth = 1.5
        outline.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        for point in annotation.resizeHandles {
            let center = transform(point)
            let handle = NSBezierPath(roundedRect: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8),
                                      xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }

    private func draw(_ annotation: Annotation, transform: (NSPoint) -> NSPoint) {
        renderer.draw(annotation, scale: displayScale, transform: transform)
    }

    private var displayScale: CGFloat {
        let rect = imageRect
        return rect.width / max(image.size.width, 1)
    }

}
