import AVFoundation
import UIKit
import Vision

/// One thing drawn on screen, in window points.
final class CapturedNode {
    enum Kind: String { case rect, text, image, vector }

    var kind: Kind
    var name: String
    var frame: CGRect
    var opacity: CGFloat = 1
    var fill: UIColor?
    var gradient: [String: Any]?
    var corner: CGFloat = 0
    var smooth = false
    var stroke: UIColor?
    var strokeWidth: CGFloat = 0
    var blur = false
    var shadow: [String: Any]?
    var text: String?
    var fontSize: CGFloat = 0
    var png: Data?
    var path: String?
    var evenOdd = false
    var children: [CapturedNode] = []

    init(kind: Kind, name: String, frame: CGRect) {
        self.kind = kind
        self.name = name
        self.frame = frame
    }

    var hasPaint: Bool { fill != nil || gradient != nil || stroke != nil || blur || shadow != nil }

    func json(parent: CGRect) -> [String: Any] {
        var out: [String: Any] = [
            "kind": kind.rawValue, "name": name,
            "x": rounded(frame.minX - parent.minX), "y": rounded(frame.minY - parent.minY),
            "w": rounded(frame.width), "h": rounded(frame.height),
        ]
        if opacity < 1 { out["opacity"] = rounded(opacity) }
        if let fill { out["fill"] = hexColor(fill) }
        if let gradient { out["gradient"] = gradient }
        if corner > 0 { out["corner"] = rounded(corner) }
        if smooth { out["smooth"] = true }
        if let stroke {
            out["stroke"] = hexColor(stroke)
            out["strokeWidth"] = rounded(strokeWidth)
        }
        if blur { out["blur"] = true }
        if let shadow { out["shadow"] = shadow }
        if let text {
            out["text"] = text
            out["fontSize"] = rounded(fontSize)
        }
        if let png { out["png"] = png.base64EncodedString() }
        if let path {
            out["path"] = path
            if evenOdd { out["evenOdd"] = true }
        }
        if !children.isEmpty { out["children"] = children.map { $0.json(parent: frame) } }
        return out
    }
}

func rounded(_ value: CGFloat) -> Double {
    (Double(value) * 100).rounded() / 100
}

/// #RRGGBBAA in sRGB.
func hexColor(_ color: UIColor) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    return String(format: "#%02X%02X%02X%02X", byte(r), byte(g), byte(b), byte(a))
}

/// Reads the top screen of the app from its layers and returns capture JSON.
@MainActor final class ScreenCapture {
    private let fontFamily: String?
    private var snapshot: UIImage?
    private var window: UIWindow?
    private var flat: [CapturedNode] = []

    init(fontFamily: String?) {
        self.fontFamily = fontFamily
    }

    func run() -> Data {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows).filter { !$0.isHidden && $0.alpha > 0 }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return Data("{}".utf8) }
        self.window = window

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: standardFormat(scale: window.screen.scale))
        snapshot = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }

        let top = visibleLayers(under: window.layer)
        walk(top, opacity: 1, clip: window.bounds)
        let root = CapturedNode(kind: .rect, name: "Screen", frame: window.bounds)
        root.children = nest(flat, in: root)
        adoptBackground(root)
        nameFrames(root)
        groupSiblings(root)

        let body: [String: Any] = [
            "version": 1,
            "app": Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "App",
            "scale": window.screen.scale,
            "fontFamily": fontFamily ?? "",
            "root": root.json(parent: root.frame),
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// sRGB, because Figma reads a PNG's numbers as sRGB and wide-colour ones would look washed out.
    private func standardFormat(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        return format
    }

    /// A presented screen covers what's under it, so only the layers from the topmost opaque
    /// full-screen sibling upward are drawn.
    private func visibleLayers(under layer: CALayer) -> [CALayer] {
        let layers = layer.sublayers ?? []
        guard let cover = layers.lastIndex(where: { covers($0, size: layer.bounds.size) }) else { return layers }
        return Array(layers[cover...])
    }

    private func covers(_ layer: CALayer, size: CGSize) -> Bool {
        guard !layer.isHidden, layer.opacity >= 1 else { return false }
        let frame = layer.convert(layer.bounds, to: window?.layer)
        guard let window, frame.contains(window.bounds) else { return false }
        if let color = layer.backgroundColor, color.alpha >= 1 { return true }
        return (layer.sublayers ?? []).contains { covers($0, size: size) }
    }

    private func walk(_ layers: [CALayer], opacity: CGFloat, clip: CGRect) {
        for layer in layers { walk(layer, opacity: opacity, clip: clip) }
    }

    private func walk(_ layer: CALayer, opacity: CGFloat, clip: CGRect) {
        guard !layer.isHidden, layer.opacity > 0.01, let window else { return }
        let frame = layer.convert(layer.bounds, to: window.layer)
        guard frame.width > 0, frame.height > 0, frame.intersects(clip) else { return }
        let alpha = opacity * CGFloat(layer.opacity)

        if layer is AVPlayerLayer {
            addVideo(layer, frame: frame, alpha: alpha, clip: clip)
            return
        }
        addNode(for: layer, frame: frame, alpha: alpha)
        let inner = layer.masksToBounds ? clip.intersection(frame) : clip
        walk(layer === window.layer ? visibleLayers(under: layer) : visibleChildren(of: layer), opacity: alpha, clip: inner)
    }

    private func visibleChildren(of layer: CALayer) -> [CALayer] {
        (layer.delegate is UIWindow || String(describing: type(of: layer.delegate as AnyObject)).contains("TransitionView"))
            ? visibleLayers(under: layer) : (layer.sublayers ?? [])
    }

    private func addNode(for layer: CALayer, frame: CGRect, alpha: CGFloat) {
        let className = String(describing: type(of: layer))
        let viewName = (layer.delegate as? UIView).map { String(describing: type(of: $0)) } ?? className

        if let shape = layer as? CAShapeLayer, let path = shape.path, let color = shape.fillColor {
            let node = CapturedNode(kind: .vector, name: "Icon", frame: frame)
            node.path = svgPath(path)
            node.evenOdd = shape.fillRule == .evenOdd
            node.fill = UIColor(cgColor: color)
            node.opacity = alpha
            flat.append(node)
            return
        }
        if let gradient = layer as? CAGradientLayer, let colors = gradient.colors as? [CGColor], !colors.isEmpty {
            let node = rect(layer, frame: frame, alpha: alpha)
            node.name = "Gradient"
            node.gradient = [
                "colors": colors.map { hexColor(UIColor(cgColor: $0)) },
                "locations": (gradient.locations ?? []).map { $0.doubleValue },
                "start": [gradient.startPoint.x, gradient.startPoint.y],
                "end": [gradient.endPoint.x, gradient.endPoint.y],
            ]
            flat.append(node)
            return
        }
        if className.contains("Backdrop") {
            let node = rect(layer, frame: frame, alpha: alpha)
            node.name = "Blur"
            node.blur = true
            // The material's look depends on what's behind it, so the screen's colour stands in.
            node.fill = pixel(at: CGPoint(x: frame.midX, y: frame.minY + max(2, min(frame.height / 4, 6))))
            flat.append(node)
            return
        }
        if layer.contents != nil, layer.sublayers?.isEmpty ?? true {
            addDrawing(layer, frame: frame, alpha: alpha)
            return
        }
        let node = rect(layer, frame: frame, alpha: alpha)
        if node.hasPaint {
            node.name = viewName.contains("Shape") ? "Shape" : "Background"
            flat.append(node)
        }
    }

    private func rect(_ layer: CALayer, frame: CGRect, alpha: CGFloat) -> CapturedNode {
        let node = CapturedNode(kind: .rect, name: "Shape", frame: frame)
        node.opacity = alpha
        if let color = layer.backgroundColor, color.alpha > 0.001 { node.fill = UIColor(cgColor: color) }
        node.corner = layer.cornerRadius
        node.smooth = layer.cornerCurve == .continuous
        if layer.borderWidth > 0, let color = layer.borderColor, color.alpha > 0.001 {
            node.stroke = UIColor(cgColor: color)
            node.strokeWidth = layer.borderWidth
        }
        if layer.shadowOpacity > 0, layer.shadowRadius > 0, let color = layer.shadowColor {
            node.shadow = [
                "color": hexColor(UIColor(cgColor: color).withAlphaComponent(CGFloat(layer.shadowOpacity))),
                "x": layer.shadowOffset.width, "y": layer.shadowOffset.height, "blur": layer.shadowRadius * 2,
            ]
        }
        return node
    }

    /// Text and images are drawn into layers, so they are told apart by reading the pixels.
    private func addDrawing(_ layer: CALayer, frame: CGRect, alpha: CGFloat) {
        let renderer = UIGraphicsImageRenderer(bounds: layer.bounds, format: standardFormat(scale: window?.screen.scale ?? 3))
        let image = renderer.image { layer.render(in: $0.cgContext) }
        if let read = recognize(image), let color = inkColor(image) {
            let node = CapturedNode(kind: .text, name: read, frame: frame)
            node.text = read
            node.fill = color
            node.fontSize = fontSize(forHeight: frame.height, lines: read.components(separatedBy: "\n").count)
            node.opacity = alpha
            flat.append(node)
            return
        }
        let node = CapturedNode(kind: .image, name: "Image", frame: frame)
        node.png = image.pngData()
        node.opacity = alpha
        flat.append(node)
    }

    private func addVideo(_ layer: CALayer, frame: CGRect, alpha: CGFloat, clip: CGRect) {
        let node = CapturedNode(kind: .image, name: "Video", frame: frame)
        node.opacity = alpha
        // The player's picture isn't in layer rendering, only in the window snapshot.
        if let snapshot, let cg = snapshot.cgImage {
            let scale = snapshot.scale
            let crop = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            if let part = cg.cropping(to: crop) { node.png = UIImage(cgImage: part).pngData() }
        }
        if let parent = layer.superlayer {
            var current: CALayer? = parent
            while let candidate = current {
                if candidate.cornerRadius > 0, candidate.masksToBounds { node.corner = candidate.cornerRadius; break }
                current = candidate.superlayer
            }
        }
        flat.append(node)
    }

    private func recognize(_ image: UIImage) -> String? {
        guard let cg = image.cgImage, let opaque = onBackground(cg) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0
        try? VNImageRequestHandler(cgImage: opaque).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            return (best.string, observation.boundingBox)
        }
        guard !lines.isEmpty else { return nil }
        // An icon can read as a stray letter. Real text fills most of its own layer.
        let covered = lines.map(\.1).reduce(CGFloat(0)) { max($0, $1.width) }
        guard covered > 0.55 else { return nil }
        return lines.sorted { $0.1.minY > $1.1.minY }.map(\.0).joined(separator: "\n")
    }

    /// Text recognition needs contrast, so ink goes on a background opposite to its own colour.
    private func onBackground(_ cg: CGImage) -> CGImage? {
        guard let ink = inkColor(UIImage(cgImage: cg)) else { return nil }
        var white: CGFloat = 0
        ink.getWhite(&white, alpha: nil)
        let margin = 8
        let size = CGSize(width: cg.width + margin * 2, height: cg.height + margin * 2)
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { context in
            (white > 0.5 ? UIColor.black : UIColor.white).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cg).draw(at: CGPoint(x: margin, y: margin))
        }
        return image.cgImage
    }

    /// The colour of the image's most solid pixels.
    private func inkColor(_ image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0, g = 0, b = 0, count = 0, top = 0
        for i in stride(from: 3, to: data.count, by: 4) { top = max(top, Int(data[i])) }
        guard top > 20 else { return nil }
        for i in stride(from: 0, to: data.count, by: 4) where Int(data[i + 3]) >= top - 2 {
            r += Int(data[i]); g += Int(data[i + 1]); b += Int(data[i + 2]); count += 1
        }
        guard count > 0 else { return nil }
        let unit = CGFloat(count) * CGFloat(top)
        return UIColor(red: CGFloat(r) / unit, green: CGFloat(g) / unit, blue: CGFloat(b) / unit, alpha: CGFloat(top) / 255)
    }

    private func fontSize(forHeight height: CGFloat, lines: Int) -> CGFloat {
        var ratio: CGFloat = 1.2
        if let fontFamily, let font = UIFont(name: fontFamily, size: 100) { ratio = font.lineHeight / 100 }
        return ((height / CGFloat(max(1, lines))) / ratio * 2).rounded() / 2
    }

    private func pixel(at point: CGPoint) -> UIColor? {
        guard let snapshot, let cg = snapshot.cgImage else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = snapshot.scale
        context.draw(cg, in: CGRect(x: -point.x * s, y: -(CGFloat(cg.height) - point.y * s), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return UIColor(red: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255, alpha: 1)
    }

    private func svgPath(_ path: CGPath) -> String {
        var out = ""
        func f(_ p: CGPoint) -> String { "\(rounded(p.x)) \(rounded(p.y))" }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: out += "M\(f(e.points[0]))"
            case .addLineToPoint: out += "L\(f(e.points[0]))"
            case .addQuadCurveToPoint: out += "Q\(f(e.points[0])) \(f(e.points[1]))"
            case .addCurveToPoint: out += "C\(f(e.points[0])) \(f(e.points[1])) \(f(e.points[2]))"
            case .closeSubpath: out += "Z"
            @unknown default: break
            }
        }
        return out
    }

    /// SwiftUI draws flat lists of layers. Grouping each one under the painted shape that holds it
    /// gives Figma the layers a designer would make: a tile holding its icon and label.
    private func nest(_ nodes: [CapturedNode], in root: CapturedNode) -> [CapturedNode] {
        var merged: [CapturedNode] = []
        for node in nodes {
            // A border is drawn as its own layer over the fill it belongs to.
            if node.kind == .rect, node.fill == nil, node.gradient == nil, node.stroke != nil,
               let base = merged.last(where: { $0.kind == .rect && same($0.frame, node.frame) }) {
                base.stroke = node.stroke
                base.strokeWidth = node.strokeWidth
                continue
            }
            merged.append(node)
        }
        cropOverflowingImages(merged)
        var top: [CapturedNode] = []
        var containers: [CapturedNode] = []
        for node in merged {
            let parent = containers.last { $0.frame.insetBy(dx: -0.5, dy: -0.5).contains(node.frame) && !same($0.frame, node.frame) }
            if let parent { parent.children.append(node) } else { top.append(node) }
            if node.kind == .rect { containers.append(node) }
        }
        return top
    }

    /// An aspect-fill picture is wider or taller than the shape showing it, and that shape's mask
    /// isn't readable from the layers. Same height or width on the shape gives it away.
    private func cropOverflowingImages(_ nodes: [CapturedNode]) {
        for node in nodes where node.kind == .image {
            guard let holder = nodes.first(where: { other in
                guard other.kind == .rect, other.corner > 0, other.frame != node.frame else { return false }
                let sameRow = abs(other.frame.minY - node.frame.minY) < 1 && abs(other.frame.height - node.frame.height) < 1 && node.frame.minX <= other.frame.minX && node.frame.maxX >= other.frame.maxX
                let sameColumn = abs(other.frame.minX - node.frame.minX) < 1 && abs(other.frame.width - node.frame.width) < 1 && node.frame.minY <= other.frame.minY && node.frame.maxY >= other.frame.maxY
                return sameRow || sameColumn
            }), let data = node.png, let image = UIImage(data: data)?.cgImage else { continue }
            let scale = CGFloat(image.width) / node.frame.width
            let crop = holder.frame.offsetBy(dx: -node.frame.minX, dy: -node.frame.minY)
            let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            guard let part = image.cropping(to: pixels) else { continue }
            node.png = UIImage(cgImage: part).pngData()
            node.frame = holder.frame
            node.corner = holder.corner
        }
    }

    /// Puts a label with the tile above it, and lines of equal things in a row, so they move as
    /// one in Figma and the plugin can give the row auto layout.
    private func groupSiblings(_ node: CapturedNode) {
        node.children.forEach(groupSiblings)
        var paired: [CapturedNode] = []
        var kids = node.children[...]
        while let first = kids.popFirst() {
            if first.kind == .rect, let label = kids.first, label.kind == .text,
               abs(label.frame.midX - first.frame.midX) < 2, label.frame.minY >= first.frame.maxY, label.frame.minY - first.frame.maxY < 16 {
                kids = kids.dropFirst()
                let group = CapturedNode(kind: .rect, name: label.text ?? "Item", frame: first.frame.union(label.frame))
                group.children = [first, label]
                paired.append(group)
            } else {
                paired.append(first)
            }
        }
        var rowed: [CapturedNode] = []
        var run: [CapturedNode] = []
        func flush() {
            if run.count >= 3 {
                let row = CapturedNode(kind: .rect, name: "Row", frame: run.dropFirst().reduce(run[0].frame) { $0.union($1.frame) })
                row.children = run
                rowed.append(row)
            } else {
                rowed += run
            }
            run = []
        }
        for kid in paired {
            if let last = run.last, abs(last.frame.minY - kid.frame.minY) > 1 || abs(last.frame.height - kid.frame.height) > 1 || kid.kind == .text { flush() }
            if kid.kind == .text { rowed.append(kid) } else { run.append(kid) }
        }
        flush()
        node.children = rowed
    }

    /// A full-screen rectangle is the screen's own background, not a layer to move around.
    private func adoptBackground(_ root: CapturedNode) {
        while let first = root.children.first, first.kind == .rect, first.frame.contains(root.frame), first.gradient == nil {
            root.fill = first.fill ?? root.fill
            root.children.removeFirst()
            root.children = first.children + root.children
        }
    }

    private func nameFrames(_ node: CapturedNode) {
        node.children.forEach(nameFrames)
        if node.kind == .image, node.name == "Image", node.frame.width < 64, node.frame.height < 64 { node.name = "Icon" }
        guard node.kind == .rect, ["Shape", "Blur", "Background", "Gradient"].contains(node.name) else { return }
        // A big shape holds many things, so one label inside it doesn't name it.
        let small = node.frame.height < 120
        if small, let label = node.children.first(where: { $0.kind == .text })?.text {
            node.name = label
        } else if node.name == "Blur" || node.name == "Shape" {
            node.name = small ? "Button" : "Panel"
        } else if node.name == "Background" {
            node.name = "Panel"
        }
    }

    private func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}
