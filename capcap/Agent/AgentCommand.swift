import AppKit
import Foundation

enum AgentCommand {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.first == "agent" else { return nil }

        do {
            let response = try AgentCLI(arguments: Array(arguments.dropFirst())).run()
            if let text = response.stdout {
                AgentIO.writeStdout(text)
            }
            if let metadataURL = response.metadataURL, let metadata = response.metadata {
                try AgentIO.writeJSON(metadata, to: metadataURL, pretty: response.pretty)
            }
            if let metadata = response.metadata {
                try AgentIO.writeJSON(metadata, to: nil, pretty: response.pretty)
            }
            return 0
        } catch AgentCLIError.help(let text) {
            AgentIO.writeStdout(text)
            return 0
        } catch let error as AgentCLIError {
            AgentIO.writeError(message: error.message, exitCode: error.exitCode)
            return error.exitCode
        } catch {
            AgentIO.writeError(message: error.localizedDescription, exitCode: 1)
            return 1
        }
    }
}

private struct AgentResponse {
    var stdout: String?
    var metadata: [String: Any]?
    var metadataURL: URL?
    var pretty: Bool = false
}

private struct AgentCLI {
    private let arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func run() throws -> AgentResponse {
        let execute = try parse()
        guard Defaults.agentCommandsEnabled else {
            throw AgentCLIError.disabled(
                "capcap agent commands are disabled; turn on Agent Command Line in capcap Settings > Permissions"
            )
        }
        return try execute()
    }

    // Parsing runs before the Settings gate so help and usage errors work while
    // agent commands are off. Keep screen, window, and file content access in
    // the returned closure.
    private func parse() throws -> () throws -> AgentResponse {
        guard let subcommand = arguments.first else {
            throw AgentCLIError.usage("Missing agent subcommand")
        }

        switch subcommand {
        case "displays":
            guard arguments.dropFirst().allSatisfy({ $0 == "--pretty" }) else {
                throw AgentCLIError.usage("Usage: capcap agent displays [--pretty]")
            }
            let pretty = arguments.contains("--pretty")
            return { AgentResponse(metadata: AgentScreenCatalog.metadata, pretty: pretty) }

        case "schema":
            guard arguments.dropFirst().allSatisfy({ $0 == "--pretty" }) else {
                throw AgentCLIError.usage("Usage: capcap agent schema [--pretty]")
            }
            let pretty = arguments.contains("--pretty")
            return { AgentResponse(metadata: AgentSpecification.schema, pretty: pretty) }

        case "validate":
            let options = try AgentAnnotateOptions.parse(Array(arguments.dropFirst()), validationOnly: true)
            return {
                let result = try AgentAnnotator.annotate(options: options, validationOnly: true)
                return AgentResponse(metadata: result.metadata, metadataURL: options.metaURL, pretty: options.pretty)
            }

        case "annotate":
            let options = try AgentAnnotateOptions.parse(Array(arguments.dropFirst()))
            return {
                let result = try AgentAnnotator.annotate(options: options)
                return AgentResponse(
                    metadata: result.metadata,
                    metadataURL: options.metaURL,
                    pretty: options.pretty
                )
            }

        case "capture":
            let options = try AgentCaptureOptions.parse(Array(arguments.dropFirst()))
            return {
                let result = try AgentCapturer.capture(options: options)
                return AgentResponse(
                    metadata: result.metadata,
                    metadataURL: options.metaURL,
                    pretty: options.pretty
                )
            }

        case "run":
            let options = try AgentRunOptions.parse(Array(arguments.dropFirst()))
            return {
                let result = try AgentRunner.run(options: options)
                return AgentResponse(
                    metadata: result.metadata,
                    metadataURL: options.metaURL,
                    pretty: options.pretty
                )
            }

        case "windows", "list-windows":
            let options = try AgentWindowsOptions.parse(Array(arguments.dropFirst()))
            return {
                let result = AgentWindowsLister.list(options: options)
                return AgentResponse(
                    metadata: result.metadata,
                    metadataURL: options.metaURL,
                    pretty: options.pretty
                )
            }

        case "help", "--help", "-h":
            throw AgentCLIError.help(Self.usageText)

        default:
            throw AgentCLIError.usage("Unknown agent subcommand \(subcommand)")
        }
    }

    fileprivate static let usageText = """
    Usage
      capcap agent annotate --input image.png --spec marks.json --out result.png
      capcap agent capture --target mouse-screen --out shot.png
      capcap agent run --target mouse-screen --spec marks.json --out result.png
      capcap agent windows --pretty
      capcap agent displays --pretty
      capcap agent schema --pretty
      capcap agent validate --input image.png --spec marks.json

    Options
      --input, -i    Source PNG or image file
      --spec, -s     JSON annotation spec
      --out, -o      Output PNG file
      --meta         Optional metadata JSON file
      --pretty       Pretty print JSON output

    Discover the complete annotation contract with agent schema
    Validate against the exact image before rendering with agent validate
    Image coordinates are pixels; capture rects/window frames are global CG points
    Agent commands are off by default; turn on Agent Command Line in capcap Settings > Permissions
    Errors are JSON on stderr; exit 64 means invalid arguments, exit 1 means operation failed, exit 77 means agent commands are disabled
    Coordinates are pixels with a top-left origin
    """
}

enum AgentCLIError: Error {
    case help(String)
    case usage(String)
    case failure(String)
    case disabled(String)

    var message: String {
        switch self {
        case .help(let text), .usage(let text), .failure(let text), .disabled(let text):
            return text
        }
    }

    var exitCode: Int32 {
        switch self {
        case .help:
            return 0
        case .usage:
            return 64
        case .failure:
            return 1
        case .disabled:
            return 77
        }
    }
}

private struct AgentAnnotateOptions {
    let inputURL: URL
    let specURL: URL
    let outputURL: URL
    let metaURL: URL?
    let pretty: Bool

    static func parse(_ arguments: [String], validationOnly: Bool = false) throws -> AgentAnnotateOptions {
        var input: String?
        var spec: String?
        var output: String?
        var meta: String?
        var pretty = false

        var index = 0
        while index < arguments.count {
            let token = arguments[index]

            if token == "--pretty" {
                pretty = true
                index += 1
                continue
            }
            if token == "--help" || token == "-h" {
                throw AgentCLIError.help(validationOnly
                    ? "Usage: capcap agent validate --input image.png --spec marks.json [--meta result.json] [--pretty]"
                    : Self.usageText)
            }

            let key: String
            let value: String

            if let split = token.firstIndex(of: "="), token.hasPrefix("--") {
                key = String(token[..<split])
                value = String(token[token.index(after: split)...])
                index += 1
            } else {
                key = token
                guard index + 1 < arguments.count else {
                    throw AgentCLIError.usage("Missing value for \(token)")
                }
                guard !arguments[index + 1].hasPrefix("--"), arguments[index + 1] != "-h" else {
                    throw AgentCLIError.usage("Missing value for \(token)")
                }
                value = arguments[index + 1]
                index += 2
            }

            switch key {
            case "--input", "-i":
                input = value
            case "--spec", "-s":
                spec = value
            case "--out", "--output", "-o":
                output = value
            case "--meta":
                meta = value
            default:
                throw AgentCLIError.usage("Unknown option \(key)")
            }
        }

        guard let input else { throw AgentCLIError.usage("Missing --input") }
        guard let spec else { throw AgentCLIError.usage("Missing --spec") }
        if validationOnly, output != nil { throw AgentCLIError.usage("validate does not accept --out") }
        guard validationOnly || output != nil else { throw AgentCLIError.usage("Missing --out") }
        let resolvedOutput = output ?? input
        try AgentIO.validatePaths(inputs: [input, spec], outputs: (validationOnly ? [] : [resolvedOutput]) + [meta].compactMap { $0 })

        return AgentAnnotateOptions(
            inputURL: AgentIO.fileURL(from: input),
            specURL: AgentIO.fileURL(from: spec),
            outputURL: AgentIO.fileURL(from: resolvedOutput),
            metaURL: meta.map(AgentIO.fileURL(from:)),
            pretty: pretty
        )
    }

    private static let usageText = """
    Usage
      capcap agent annotate --input image.png --spec marks.json --out result.png

    Options
      --input, -i        Source PNG or image file
      --spec, -s         JSON annotation spec
      --out, -o          Output PNG file
      --meta             Optional metadata JSON file
      --pretty           Pretty print JSON output

    Annotation types
      rect, rectangle, box
      ellipse, oval, circle
      arrow, line, text, label
      number, numbered, badge
      mosaic, pixelate, blur
      magnifier, loupe, spotlight
      pen, path
      marker, highlight, highlighter

    Specs use pixel coordinates with a top-left origin
    """
}

struct AgentAnnotateResult {
    let metadata: [String: Any]
}

enum AgentAnnotator {
    fileprivate static func annotate(options: AgentAnnotateOptions, validationOnly: Bool = false) throws -> AgentAnnotateResult {
        let inputData: Data
        do {
            inputData = try Data(contentsOf: options.inputURL)
        } catch {
            throw AgentCLIError.failure("Could not read input image \(options.inputURL.path)")
        }

        guard let baseImage = NSImage.imagePreservingPixelDimensions(from: inputData) else {
            throw AgentCLIError.failure("Could not decode input image \(options.inputURL.path)")
        }
        guard baseImage.size.width > 0, baseImage.size.height > 0 else {
            throw AgentCLIError.failure("Input image has zero size")
        }

        return try annotate(
            baseImage: baseImage,
            inputDescription: options.inputURL.path,
            specURL: options.specURL,
            outputURL: options.outputURL,
            command: "agent annotate",
            extraMetadata: [:],
            validationOnly: validationOnly
        )
    }

    static func annotate(
        baseImage: NSImage,
        inputDescription: String,
        specURL: URL,
        outputURL: URL,
        command: String,
        extraMetadata: [String: Any],
        validationOnly: Bool = false
    ) throws -> AgentAnnotateResult {
        let specData: Data
        do {
            specData = try Data(contentsOf: specURL)
        } catch {
            throw AgentCLIError.failure("Could not read spec \(specURL.path)")
        }

        try AgentSpecification.validateKeys(specData)
        let document = try AgentIO.decode(AgentAnnotationDocument.self, from: specData)

        try document.validate()
        let finish = try AgentIO.decode(AgentImageFinish.self, from: specData)
        try finish.validate(imageSize: baseImage.size)
        if let size = document.imageSize, size != [Int(baseImage.size.width), Int(baseImage.size.height)] {
            throw AgentCLIError.failure("imageSize does not match input pixels; inspect the current image and regenerate the spec")
        }
        let mapper = AgentCoordinateMapper(imageSize: baseImage.size)
        let annotations = try document.annotations.enumerated().map { index, spec in
            do {
                return try spec.makeAnnotation(mapper: mapper, baseImage: baseImage, index: index)
            } catch {
                let message = (error as? AgentCLIError)?.message ?? error.localizedDescription
                throw AgentCLIError.failure("annotations[\(index)]: \(message)")
            }
        }

        if validationOnly {
            return AgentAnnotateResult(metadata: ["ok": true, "command": "agent validate", "input": inputDescription,
                "spec": specURL.path, "annotations": annotations.count,
                "image": ["width": Int(baseImage.size.width), "height": Int(baseImage.size.height)],
                "coordinateSpace": "pixels", "origin": "top-left"])
        }

        let annotated = try AgentAnnotationRenderer.render(
            baseImage: baseImage,
            annotations: annotations
        )

        let rendered = try finish.render(annotated)
        guard let pngData = rendered.pngDataPreservingBacking() else {
            throw AgentCLIError.failure("Could not encode output PNG")
        }

        try AgentIO.ensureParentDirectory(for: outputURL)
        do {
            try pngData.write(to: outputURL, options: .atomic)
        } catch {
            throw AgentCLIError.failure("Could not write output \(outputURL.path)")
        }

        let cgImage = rendered.cgImagePreservingBacking()
        let width = cgImage?.width ?? Int(rendered.size.width.rounded())
        let height = cgImage?.height ?? Int(rendered.size.height.rounded())

        var metadata: [String: Any] = [
            "ok": true,
            "command": command,
            "input": inputDescription,
            "spec": specURL.path,
            "out": outputURL.path,
            "image": [
                "width": width,
                "height": height
            ],
            "coordinateSpace": "pixels",
            "origin": "top-left",
            "annotations": annotations.count,
            "annotationImage": ["width": Int(baseImage.size.width), "height": Int(baseImage.size.height)],
            "presentation": finish.metadata
        ]
        for (key, value) in extraMetadata {
            metadata[key] = value
        }

        return AgentAnnotateResult(metadata: metadata)
    }
}

private struct AgentAnnotationDocument: Decodable {
    let version: Int?
    let imageSize: [Int]?
    let coordinateSpace: String?
    let origin: String?
    let annotations: [AgentAnnotationSpec]

    func validate() throws {
        if let version, version != 1 {
            throw AgentCLIError.failure("Unsupported spec version \(version)")
        }
        if let coordinateSpace, coordinateSpace != "pixels" {
            throw AgentCLIError.failure("Unsupported coordinateSpace \(coordinateSpace)")
        }
        if let origin, origin != "top-left" {
            throw AgentCLIError.failure("Unsupported origin \(origin)")
        }
    }
}

private struct AgentAnnotationSpec: Decodable {
    let type: String
    let rect: AgentRect?
    let from: AgentPoint?
    let to: AgentPoint?
    let start: AgentPoint?
    let end: AgentPoint?
    let at: AgentPoint?
    let center: AgentPoint?
    let points: [AgentPoint]?
    let text: String?
    let color: String?
    let lineWidth: Double?
    let fill: Bool?
    let fillMode: String?
    let strokeStyle: String?
    let style: String?
    let rotation: Double?
    let rotationDegrees: Double?
    let rotationRadians: Double?
    let fontSize: Double?
    let stroke: Bool?
    let callout: Bool?
    let tip: AgentPoint?
    let control: AgentPoint?
    let controlPoint: AgentPoint?
    let number: Int?
    let blockSize: Double?
    let radius: Double?
    let zoom: Double?
    let source: AgentPoint?

    func makeAnnotation(
        mapper: AgentCoordinateMapper,
        baseImage: NSImage,
        index: Int
    ) throws -> Annotation {
        switch normalizedType {
        case "rect", "rectangle", "box":
            let rect = try requireRect().canvasRect(using: mapper)
            return RectAnnotation(
                rect: rect,
                color: try resolvedColor(default: AgentColor.defaultRed),
                lineWidth: try positive(lineWidth, fallback: 4, name: "lineWidth"),
                fillMode: try resolvedFillMode(),
                strokeStyle: try resolvedStrokeStyle(),
                rotation: resolvedRotation()
            )

        case "ellipse", "oval", "circle":
            let rect = try requireRect().canvasRect(using: mapper)
            let strokeStyle = try resolvedStrokeStyle()
            return EllipseAnnotation(
                rect: rect,
                color: try resolvedColor(default: AgentColor.defaultRed),
                lineWidth: try positive(lineWidth, fallback: 4, name: "lineWidth"),
                fillMode: try resolvedFillMode(),
                strokeStyle: strokeStyle == .rounded ? .standard : strokeStyle,
                rotation: resolvedRotation()
            )

        case "arrow":
            return ArrowAnnotation(
                startPoint: try requireStartPoint().canvasPoint(using: mapper),
                endPoint: try requireEndPoint().canvasPoint(using: mapper),
                color: try resolvedColor(default: AgentColor.defaultRed),
                lineWidth: try positive(lineWidth, fallback: 5, name: "lineWidth"),
                style: try resolvedArrowStyle(),
                controlPoint: (controlPoint ?? control)?.canvasPoint(using: mapper)
            )

        case "line":
            return LineAnnotation(
                startPoint: try requireStartPoint().canvasPoint(using: mapper),
                endPoint: try requireEndPoint().canvasPoint(using: mapper),
                color: try resolvedColor(default: AgentColor.defaultRed),
                lineWidth: try positive(lineWidth, fallback: 4, name: "lineWidth")
            )

        case "text", "label":
            guard let text else {
                throw AgentCLIError.failure("Text annotation is missing text")
            }
            let resolvedFontSize = try positive(fontSize, fallback: 24, name: "fontSize")
            let size = TextAnnotation.editorSize(
                for: text,
                font: TextAnnotation.font(forSize: resolvedFontSize)
            )
            let topLeft = at ?? rect?.originPoint
            guard let topLeft else {
                throw AgentCLIError.failure("Text annotation is missing at")
            }
            return TextAnnotation(
                text: text,
                origin: mapper.textOrigin(topLeft: topLeft, textSize: size),
                color: try resolvedColor(default: AgentColor.defaultRed),
                fontSize: resolvedFontSize,
                rotation: resolvedRotation(),
                hasStroke: stroke ?? false,
                hasCallout: callout ?? false,
                calloutTip: tip?.canvasPoint(using: mapper)
            )

        case "number", "numbered", "badge":
            guard let center else {
                throw AgentCLIError.failure("Number annotation is missing center")
            }
            return NumberAnnotation(
                center: center.canvasPoint(using: mapper),
                tip: tip?.canvasPoint(using: mapper),
                controlPoint: (controlPoint ?? control)?.canvasPoint(using: mapper),
                number: number ?? index + 1,
                color: try resolvedColor(default: AgentColor.defaultRed)
            )

        case "spotlight":
            return SpotlightAnnotation(rect: try requireRect().canvasRect(using: mapper))

        case "mosaic", "pixelate", "blur":
            let canvasRect = try requireRect().canvasRect(using: mapper)
            let blockSize = try positive(blockSize, fallback: 12, name: "blockSize")
            let mosaicStyle: MosaicStyle = normalizedType == "blur" ? .blur : .pixelate
            let blurRadius = Defaults.normalizedMosaicBlurRadius(
                try positive(radius, fallback: blockSize, name: "radius")
            )
            guard let region = MosaicTool.createMosaicRegion(
                rect: canvasRect,
                imageSize: mapper.imageSize,
                baseImage: baseImage,
                blockSize: blockSize,
                style: mosaicStyle,
                blurRadius: blurRadius
            ) else {
                throw AgentCLIError.failure("Could not create mosaic annotation")
            }
            return MosaicAnnotation(
                rect: region.rect,
                pixelatedImage: region.pixelatedImage,
                blockSize: blockSize,
                style: mosaicStyle,
                blurRadius: blurRadius
            )

        case "magnifier", "loupe":
            guard let center else {
                throw AgentCLIError.failure("Magnifier annotation is missing center")
            }
            return MagnifierAnnotation(
                center: center.canvasPoint(using: mapper),
                radius: try positive(radius, fallback: 64, name: "radius"),
                color: try resolvedColor(default: AgentColor.defaultRed),
                lineWidth: try positive(lineWidth, fallback: 4, name: "lineWidth"),
                zoom: try positive(zoom, fallback: MagnifierAnnotation.defaultZoom, name: "zoom"),
                sourceImage: baseImage,
                sourceCenter: source?.canvasPoint(using: mapper)
            )

        case "pen", "path":
            return PenAnnotation(
                path: try smoothedPath(using: mapper),
                color: try resolvedColor(default: AgentColor.defaultRed),
                lineWidth: try positive(lineWidth, fallback: 4, name: "lineWidth"),
                rotation: resolvedRotation()
            )

        case "marker", "highlight", "highlighter":
            return MarkerAnnotation(
                path: try smoothedPath(using: mapper),
                color: try resolvedColor(default: AgentColor.defaultYellow),
                lineWidth: try positive(lineWidth, fallback: 5, name: "lineWidth"),
                rotation: resolvedRotation()
            )

        default:
            throw AgentCLIError.failure("Unsupported annotation type \(type)")
        }
    }

    private var normalizedType: String {
        type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private func requireRect() throws -> AgentRect {
        guard let rect else {
            throw AgentCLIError.failure("\(type) annotation is missing rect")
        }
        return rect
    }

    private func requireStartPoint() throws -> AgentPoint {
        if let from { return from }
        if let start { return start }
        throw AgentCLIError.failure("\(type) annotation is missing from")
    }

    private func requireEndPoint() throws -> AgentPoint {
        if let to { return to }
        if let end { return end }
        throw AgentCLIError.failure("\(type) annotation is missing to")
    }

    private func smoothedPath(using mapper: AgentCoordinateMapper) throws -> NSBezierPath {
        guard let points, !points.isEmpty else {
            throw AgentCLIError.failure("\(type) annotation is missing points")
        }
        return NSBezierPath.smoothed(through: points.map { $0.canvasPoint(using: mapper) })
    }

    private func positive(_ value: Double?, fallback: CGFloat, name: String) throws -> CGFloat {
        guard let value else { return fallback }
        guard value.isFinite, value > 0 else {
            throw AgentCLIError.failure("Annotation \(name) must be a positive number")
        }
        return CGFloat(value)
    }

    private func resolvedColor(default defaultColor: NSColor) throws -> NSColor {
        guard let color else { return defaultColor }
        guard let parsed = AgentColor.parse(color) else {
            throw AgentCLIError.failure("Invalid annotation color \(color)")
        }
        return parsed
    }

    private func resolvedFillMode() throws -> ShapeFillMode {
        if let fillMode {
            switch fillMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "none":
                return .none
            case "opaque", "solid":
                return .opaque
            case "translucent", "transparent":
                return .translucent
            default:
                throw AgentCLIError.failure("Unsupported annotation fillMode \(fillMode)")
            }
        }
        return fill == true ? .opaque : .none
    }

    private func resolvedStrokeStyle() throws -> ShapeStrokeStyle {
        guard let strokeStyle else { return .standard }
        switch strokeStyle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "standard":
            return .standard
        case "rounded", "round", "roundedrect", "rounded-rect", "roundedrectangle", "rounded-rectangle":
            return .rounded
        case "handdrawn", "hand-drawn", "rough":
            return .handDrawn
        default:
            throw AgentCLIError.failure("Unsupported annotation strokeStyle \(strokeStyle)")
        }
    }

    private func resolvedArrowStyle() throws -> ArrowStyle {
        guard let style else { return .tapered }
        switch style.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tapered":
            return .tapered
        case "doubleended", "double-ended", "double":
            return .doubleEnded
        case "line":
            return .line
        case "dottail", "dot-tail", "dot":
            return .dotTail
        default:
            throw AgentCLIError.failure("Unsupported annotation arrow style \(style)")
        }
    }

    private func resolvedRotation() -> CGFloat {
        if let rotationRadians, rotationRadians.isFinite {
            return CGFloat(rotationRadians)
        }
        if let rotationDegrees, rotationDegrees.isFinite {
            return CGFloat(rotationDegrees * .pi / 180)
        }
        if let rotation, rotation.isFinite {
            return CGFloat(rotation * .pi / 180)
        }
        return 0
    }
}

private struct AgentPoint: Decodable {
    let x: CGFloat
    let y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            let x = try array.decode(Double.self)
            let y = try array.decode(Double.self)
            self.x = CGFloat(x)
            self.y = CGFloat(y)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = CGFloat(try container.decode(Double.self, forKey: .x))
        y = CGFloat(try container.decode(Double.self, forKey: .y))
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }

    func canvasPoint(using mapper: AgentCoordinateMapper) -> NSPoint {
        mapper.point(fromTopLeft: self)
    }
}

private struct AgentRect: Decodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            let x = try array.decode(Double.self)
            let y = try array.decode(Double.self)
            let width = try array.decode(Double.self)
            let height = try array.decode(Double.self)
            self.x = CGFloat(x)
            self.y = CGFloat(y)
            self.width = CGFloat(width)
            self.height = CGFloat(height)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = CGFloat(try container.decode(Double.self, forKey: .x))
        y = CGFloat(try container.decode(Double.self, forKey: .y))
        if let width = try container.decodeIfPresent(Double.self, forKey: .width) {
            self.width = CGFloat(width)
        } else {
            self.width = CGFloat(try container.decode(Double.self, forKey: .w))
        }
        if let height = try container.decodeIfPresent(Double.self, forKey: .height) {
            self.height = CGFloat(height)
        } else {
            self.height = CGFloat(try container.decode(Double.self, forKey: .h))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
        case w
        case h
    }

    var originPoint: AgentPoint {
        AgentPoint(x: x, y: y)
    }

    func canvasRect(using mapper: AgentCoordinateMapper) throws -> NSRect {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw AgentCLIError.failure("Annotation rect must have positive size")
        }
        return mapper.rect(fromTopLeft: self)
    }

    private init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
        self.width = 0
        self.height = 0
    }
}

private struct AgentCoordinateMapper {
    let imageSize: NSSize

    func point(fromTopLeft point: AgentPoint) -> NSPoint {
        NSPoint(x: point.x, y: imageSize.height - point.y)
    }

    func rect(fromTopLeft rect: AgentRect) -> NSRect {
        NSRect(
            x: rect.x,
            y: imageSize.height - rect.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    func textOrigin(topLeft: AgentPoint, textSize: NSSize) -> NSPoint {
        NSPoint(
            x: topLeft.x,
            y: imageSize.height - topLeft.y - textSize.height
        )
    }
}

private enum AgentAnnotationRenderer {
    static func render(baseImage: NSImage, annotations: [Annotation]) throws -> NSImage {
        guard let baseCGImage = baseImage.cgImagePreservingBacking() else {
            throw AgentCLIError.failure("Could not prepare output bitmap")
        }

        let width = baseCGImage.width
        let height = baseCGImage.height
        let colorSpace = baseCGImage.colorSpace.flatMap { space in
            space.model == .rgb ? space : nil
        } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AgentCLIError.failure("Could not prepare output bitmap")
        }

        let imageBounds = NSRect(origin: .zero, size: baseImage.size)
        context.saveGState()
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(baseCGImage, in: imageBounds)
        context.restoreGState()

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        var spotlightRects: [NSRect] = []
        for annotation in annotations {
            if let spotlight = annotation as? SpotlightAnnotation {
                spotlightRects.append(spotlight.rect)
            } else {
                annotation.drawApplyingTransforms(in: context, bounds: imageBounds)
            }
        }
        SpotlightAnnotation.drawDimmingOverlay(highlightRects: spotlightRects, in: context, bounds: imageBounds)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let renderedCGImage = context.makeImage() else {
            throw AgentCLIError.failure("Could not prepare output image")
        }
        return NSImage(cgImage: renderedCGImage, size: baseImage.size)
    }
}

private enum AgentColor {
    static let defaultRed = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0)
    static let defaultYellow = NSColor(srgbRed: 1.0, green: 0.8, blue: 0.0, alpha: 1.0)

    static func parse(_ value: String) -> NSColor? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }

        if trimmed.count == 3 {
            trimmed = trimmed.map { "\($0)\($0)" }.joined()
        }

        guard trimmed.count == 6 || trimmed.count == 8,
              let raw = UInt64(trimmed, radix: 16)
        else {
            return nil
        }

        let hasAlpha = trimmed.count == 8
        let r = CGFloat((raw >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((raw >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((raw >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(raw & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

enum AgentIO {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let context: DecodingError.Context
            let detail: String
            switch error {
            case DecodingError.keyNotFound(let key, let value):
                context = value
                detail = "missing \(key.stringValue)"
            case DecodingError.typeMismatch(_, let value), DecodingError.valueNotFound(_, let value), DecodingError.dataCorrupted(let value):
                context = value
                detail = value.debugDescription
            default:
                throw AgentCLIError.failure("Invalid spec: \(error.localizedDescription)")
            }
            let path = context.codingPath.reduce("spec") { result, key in
                key.intValue.map { "\(result)[\($0)]" } ?? "\(result).\(key.stringValue)"
            }
            throw AgentCLIError.failure("\(path): \(detail)")
        }
    }

    static func validatePaths(inputs: [String], outputs: [String]) throws {
        guard (inputs + outputs).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AgentCLIError.usage("File paths must not be empty")
        }
        let inputURLs = inputs.map { fileURL(from: $0).resolvingSymlinksInPath() }
        let outputURLs = outputs.map { fileURL(from: $0).resolvingSymlinksInPath() }
        guard Set(outputURLs).count == outputURLs.count,
              !outputURLs.contains(where: { inputURLs.contains($0) }) else {
            throw AgentCLIError.usage("Output paths must be distinct from inputs and each other")
        }
    }

    static func writeError(message: String, exitCode: Int32) {
        let code: String
        switch exitCode {
        case 64: code = "invalid_arguments"
        case 77: code = "agent_disabled"
        default: code = "operation_failed"
        }
        let object: [String: Any] = ["ok": false, "error": ["code": code, "message": message], "exitCode": Int(exitCode)]
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            writeStderr(text)
        }
    }

    static func fileURL(from path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
    }

    static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    static func writeJSON(_ object: [String: Any], to url: URL?, pretty: Bool) throws {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty {
            options.insert(.prettyPrinted)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        if let url {
            try ensureParentDirectory(for: url)
            try data.write(to: url, options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            writeStdout("")
        }
    }

    static func writeStdout(_ text: String) {
        guard let data = "\(text)\n".data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    static func writeStderr(_ text: String) {
        guard let data = "\(text)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
