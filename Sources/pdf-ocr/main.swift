// pdf-ocr — WWDC25 Vision + Quartz PDFContext, in-place OCR layer on top.

import Foundation
import Vision
import PDFKit
import CoreGraphics
import CoreText
import CoreImage
import AppKit

struct Options {
    var path: String = ""
    var dpi: CGFloat = 300
    var enhance: Bool = false
    var inPlace: Bool = true
    var languages: [String] = ["en-US"]
    var fast: Bool = false
    var force: Bool = false
}

let helpText = """
PDF OCR - Apple Vision Framework

Usage:
  pdf-ocr <file-or-folder> [options]

Options:
  --dpi <value>       Resolution for OCR (default: 600)
  --no-enhance        Disable image enhancement
  --no-in-place       Create separate _ocr.pdf files
  --lang <codes>      Comma-separated language codes (default: en-US)
  --fast              Fast recognition mode
  --force             Process PDFs even if they already have text
  -h, --help          Show this help
"""

func parseArgs(_ args: [String]) -> Options? {
    var opts = Options()
    var i = 1
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": print(helpText); exit(0)
        case "--dpi":
            i += 1
            guard i < args.count, let v = Double(args[i]) else { return nil }
            opts.dpi = CGFloat(v)
        case "--no-enhance": opts.enhance = false
        case "--no-in-place": opts.inPlace = false
        case "--lang":
            i += 1
            guard i < args.count else { return nil }
            opts.languages = args[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        case "--fast": opts.fast = true
        case "--force": opts.force = true
        default:
            if opts.path.isEmpty { opts.path = (a as NSString).expandingTildeInPath }
        }
        i += 1
    }
    if opts.path.isEmpty { print(helpText); return nil }
    return opts
}

func collectPDFs(at path: String) -> [URL] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
    let url = URL(fileURLWithPath: path)
    if !isDir.boolValue {
        return url.pathExtension.lowercased() == "pdf" ? [url] : []
    }
    var out: [URL] = []
    if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let f as URL in en where f.pathExtension.lowercased() == "pdf" {
            out.append(f)
        }
    }
    return out.sorted { $0.path < $1.path }
}

func rasterize(page: PDFPage, dpi: CGFloat) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let pixelW = Int(bounds.width * scale)
    let pixelH = Int(bounds.height * scale)
    guard pixelW > 0, pixelH > 0 else { return nil }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: pixelW, height: pixelH,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
    ctx.scaleBy(x: scale, y: scale)
    let rotation = page.rotation
    if rotation != 0 {
        ctx.translateBy(x: bounds.width / 2, y: bounds.height / 2)
        ctx.rotate(by: CGFloat(-rotation) * .pi / 180)
        ctx.translateBy(x: -bounds.width / 2, y: -bounds.height / 2)
    }
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

func enhance(_ image: CGImage) -> CGImage {
    let ci = CIImage(cgImage: image)
    guard let filter = CIFilter(name: "CINoiseReduction") else { return image }
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(0.02, forKey: "inputNoiseLevel")
    filter.setValue(0.40, forKey: "inputSharpness")
    guard let out = filter.outputImage else { return image }
    let ctx = CIContext()
    return ctx.createCGImage(out, from: out.extent) ?? image
}

struct OCRLine {
    let transcript: String
    let topLeft: NormalizedPoint
    let topRight: NormalizedPoint
    let bottomLeft: NormalizedPoint
    let bottomRight: NormalizedPoint
}

@available(macOS 26.0, *)
func ocrPage(_ image: CGImage, languages: [String], fast: Bool) async -> [OCRLine] {
    var req = RecognizeDocumentsRequest()
    var opts = req.textRecognitionOptions
    opts.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
    opts.useLanguageCorrection = !fast
    req.textRecognitionOptions = opts
    do {
        let observations = try await req.perform(on: image)
        var lines: [OCRLine] = []
        for obs in observations {
            collect(container: obs.document, into: &lines)
        }
        return lines
    } catch {
        FileHandle.standardError.write(Data("OCR error: \(error.localizedDescription)\n".utf8))
        return []
    }
}

@available(macOS 26.0, *)
func collect(container: DocumentObservation.Container, into out: inout [OCRLine]) {
    for paragraph in container.paragraphs {
        for line in paragraph.lines {
            out.append(OCRLine(
                transcript: line.transcript,
                topLeft: line.topLeft,
                topRight: line.topRight,
                bottomLeft: line.bottomLeft,
                bottomRight: line.bottomRight
            ))
        }
    }
}

func writeOCRedPDF(source: URL, dest: URL, pageLines: [[OCRLine]]) -> Bool {
    guard let cgDoc = CGPDFDocument(source as CFURL) else { return false }
    guard let writeCtx = CGContext(dest as CFURL, mediaBox: nil, nil) else { return false }
    let pageCount = cgDoc.numberOfPages
    for i in 1...pageCount {
        guard let cgPage = cgDoc.page(at: i) else { continue }
        var mediaBox = cgPage.getBoxRect(.mediaBox)
        writeCtx.beginPage(mediaBox: &mediaBox)
        writeCtx.drawPDFPage(cgPage)
        let lines = i - 1 < pageLines.count ? pageLines[i - 1] : []
        if #available(macOS 26.0, *) {
            drawInvisibleText(lines, in: writeCtx, pageRect: mediaBox)
        }
        writeCtx.endPage()
    }
    writeCtx.closePDF()
    return true
}

@available(macOS 26.0, *)
func drawInvisibleText(_ lines: [OCRLine], in ctx: CGContext, pageRect: CGRect) {
    guard !lines.isEmpty else { return }
    let pageSize = pageRect.size
    for line in lines {
        let text = line.transcript
        guard !text.isEmpty else { continue }
        let bl = line.bottomLeft.toImageCoordinates(pageSize, origin: .lowerLeft)
        let br = line.bottomRight.toImageCoordinates(pageSize, origin: .lowerLeft)
        let tl = line.topLeft.toImageCoordinates(pageSize, origin: .lowerLeft)
        let baseLen = hypot(br.x - bl.x, br.y - bl.y)
        let height = hypot(tl.x - bl.x, tl.y - bl.y)
        guard baseLen > 0.5, height > 0.5 else { continue }
        let font = CTFontCreateWithName("Helvetica" as CFString, 1.0, nil)
        let attrString = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attrString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let measured = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
        guard measured > 0, (ascent + descent) > 0 else { continue }
        let scaleY = height / (ascent + descent)
        let scaleX = baseLen / measured
        let baselineLift = descent * scaleY
        let angle = atan2(br.y - bl.y, br.x - bl.x)
        ctx.saveGState()
        ctx.translateBy(x: bl.x, y: bl.y)
        ctx.rotate(by: angle)
        ctx.translateBy(x: 0, y: baselineLift)
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        ctx.setTextDrawingMode(.invisible)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }
}

func hasExistingText(_ doc: PDFDocument) -> Bool {
    guard let s = doc.string else { return false }
    return s.trimmingCharacters(in: .whitespacesAndNewlines).count > 16
}

@available(macOS 26.0, *)
func process(_ url: URL, opts: Options) async {
    guard let doc = PDFDocument(url: url) else {
        FileHandle.standardError.write(Data("Cannot open PDF: \(url.path)\n".utf8))
        return
    }
    if !opts.force, hasExistingText(doc) {
        print("  Skipping - already has text")
        return
    }
    print("Processing: \(url.lastPathComponent)")
    let count = doc.pageCount
    var pageLines: [[OCRLine]] = Array(repeating: [], count: count)
    await withTaskGroup(of: (Int, [OCRLine]).self) { group in
        for idx in 0..<count {
            guard let page = doc.page(at: idx) else { continue }
            guard var img = rasterize(page: page, dpi: opts.dpi) else { continue }
            if opts.enhance { img = enhance(img) }
            let langs = opts.languages
            let fast = opts.fast
            group.addTask {
                let lines = await ocrPage(img, languages: langs, fast: fast)
                return (idx, lines)
            }
        }
        for await (idx, lines) in group {
            pageLines[idx] = lines
            print("  Page \(idx + 1)/\(count): \(lines.count) lines")
        }
    }
    let finalDest: URL
    if opts.inPlace {
        finalDest = url
    } else {
        let base = url.deletingPathExtension().lastPathComponent
        finalDest = url.deletingLastPathComponent().appendingPathComponent("\(base)_ocr.pdf")
    }
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".pdf-ocr-\(UUID().uuidString).pdf")
    guard writeOCRedPDF(source: url, dest: tmp, pageLines: pageLines) else {
        try? FileManager.default.removeItem(at: tmp)
        return
    }
    do {
        if FileManager.default.fileExists(atPath: finalDest.path) {
            try FileManager.default.removeItem(at: finalDest)
        }
        try FileManager.default.moveItem(at: tmp, to: finalDest)
    } catch {
        FileHandle.standardError.write(Data("Cannot save PDF: \(finalDest.path)\n".utf8))
        try? FileManager.default.removeItem(at: tmp)
    }
}

@main
struct Main {
    static func main() async {
        guard let opts = parseArgs(CommandLine.arguments) else { exit(1) }
        let pdfs = collectPDFs(at: opts.path)
        if pdfs.isEmpty { print("No PDF files found"); return }
        if #available(macOS 26.0, *) {
            for f in pdfs { await process(f, opts: opts) }
        } else {
            FileHandle.standardError.write(Data("Requires macOS 26.0+\n".utf8))
            exit(1)
        }
    }
}
