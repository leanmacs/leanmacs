// Draws the sentence "the window draws this" with Core Text, as macOS draws
// it, and writes the drawings and the glyphs' positions as fixtures.
//
//   swift tools/coretext/capture.swift <font file> <directory to write in>
//   swift tools/coretext/capture.swift --positions <font file> <file to write>
//
// Run by hand, on macOS, through `mise run coretext-reference` (and, the
// second form, `mise run coretext-menlo`); never by the gate, which needs
// only the files checked in. tests/coretext/README.md says what each file
// is, how it was last captured and when to capture it again.
//
// The font is loaded from the bytes of the file given: nothing is installed
// or registered on the system. The sentence is one CTLine at 14 points.
//
// The first form writes, into the directory:
//
// - `sentence.png`: drawn on a bitmap scaled by 2, as TextEdit draws 14 pt
//   on a display of scale 2, in black on a white ground, with font
//   smoothing on, subpixel positioning and quantisation left at the
//   context's defaults. Its values are the drawing's red channel as it is
//   (255 is the white ground). This is the drawing the renderer's weight
//   was fitted to, and it is made exactly as it was on 2026-11-14.
// - `sentence-dark.png`: the same at scale 2, `#d8dee9` on `#2e3440`, the
//   default theme's text on its ground.
// - `sentence-14.png`: 14 pt at scale 1, black on white.
// - `sentence-14-dark.png`: 14 pt at scale 1, `#d8dee9` on `#2e3440`.
// - `sentence-grey.png`: at scale 2, `#808080` on white, which tells a
//   luminance bucket of the encoded value (1) from one of linear light (0).
// - `positions.txt`: each glyph's place on the line, at scale 1 and 2.
//
// Every drawing is made as native apps draw text (`CTLineDraw` with the
// context's default subpixel flags), so that Core Text places each glyph
// on its own grid, x floored to a quarter of a point: a quarter of a pixel
// at scale 1 and a half at scale 2. The renderer's painter places glyphs
// on the same grid, so the Core Text adapter's masks are compared with
// these drawings as they are. Smoothing is on. The values of each of the
// four drawings after `sentence.png` are the coverage, 255 being full
// ink: each channel's value mapped back through its ground and its text
// colour, `(value - ground) / (text - ground)`.
//
// Before it writes a drawing, it checks that no glyph reaches the bitmap's
// border, and that red, green and blue agree: within 1 for `sentence.png`,
// and within 2 of 255 as one coverage for the others. Smoothing on macOS is
// not by colour stripes, and if it were the script would refuse rather
// than pick a channel.
//
// `positions.txt` has one line per glyph per scale:
//
//   <scale> <glyph id> <x px> <y px> <advance px>
//
// in device pixels from the line's origin: x and y from the line's run
// (CTRunGetGlyphs, CTRunGetPositions), and the advance from the font's own
// metrics (CTFontGetAdvancesForGlyphs, which no tracking or kerning
// changes). Comment lines start with `#`. The second form writes only this
// file, for a font such as Menlo that is not checked in: for a collection
// (`.ttc`) its first face.
//
// It prints each bitmap's size, its baseline and, for `sentence.png` and a
// second drawing with smoothing off, the two counts the renderer's test
// makes: how many pixels are darker than mid-grey (below 128), and the ink,
// how far below the white ground the pixels are, summed. The second
// drawing is for a person, to show what smoothing does, and is not written.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sentence = "the window draws this"
let points: CGFloat = 14
// The margin around the line, in pixels.
let margin = 16

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("capture: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// A colour as 8-bit sRGB values.
struct RGB {
    let red: Int
    let green: Int
    let blue: Int

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255,
            alpha: 1)
    }
}

let black = RGB(red: 0, green: 0, blue: 0)
let white = RGB(red: 255, green: 255, blue: 255)
let light = RGB(red: 0xd8, green: 0xde, blue: 0xe9)
let dark = RGB(red: 0x2e, green: 0x34, blue: 0x40)
let grey = RGB(red: 0x80, green: 0x80, blue: 0x80)

/// The sentence as one line in `font`, its text in `color`.
func makeLine(_ font: CTFont, _ color: RGB) -> CTLine {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
    ]
    return CTLineCreateWithAttributedString(
        NSAttributedString(string: sentence, attributes: attributes))
}

/// Where a line is drawn on a bitmap of one scale.
struct Layout {
    let scale: CGFloat
    let pixelsWide: Int
    let pixelsHigh: Int
    // The baseline, in pixels from the bottom: a whole pixel.
    let baseline: Int
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(_ line: CTLine, scale: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let above = Int((ascent * scale).rounded(.up))
        let below = Int((descent * scale).rounded(.up))
        self.scale = scale
        self.pixelsWide = Int((width * scale).rounded(.up)) + 2 * margin
        self.pixelsHigh = above + below + 2 * margin
        self.baseline = margin + below
        self.width = width
        self.ascent = ascent
        self.descent = descent
    }
}

/// The bitmap of `line` drawn on `layout` over `ground`, with font smoothing
/// on or off, as bytes in memory order blue, green, red, alpha. Subpixel
/// positioning and quantisation are left at the context's defaults, as
/// native apps leave them.
func draw(_ line: CTLine, _ layout: Layout, ground: RGB, smoothed: Bool) -> [UInt8] {
    let (pixelsWide, pixelsHigh, scale) = (layout.pixelsWide, layout.pixelsHigh, layout.scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
        let context = CGContext(
            data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: pixelsWide * 4, space: space, bitmapInfo: info)
    else {
        fail("cannot make a bitmap of \(pixelsWide) by \(pixelsHigh)")
    }
    context.setFillColor(ground.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(smoothed)
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(
        x: CGFloat(margin) / scale, y: CGFloat(layout.baseline) / scale)
    CTLineDraw(line, context)
    let bytes = context.data!.bindMemory(to: UInt8.self, capacity: pixelsWide * pixelsHigh * 4)
    return Array(UnsafeBufferPointer(start: bytes, count: pixelsWide * pixelsHigh * 4))
}

/// The red channel of `bgra`, row by row from the top, checked: nothing
/// drawn on the border, and the three channels alike within 1.
func gray(_ bgra: [UInt8], _ layout: Layout) -> [UInt8] {
    let (pixelsWide, pixelsHigh) = (layout.pixelsWide, layout.pixelsHigh)
    var values = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh)
    for y in 0..<pixelsHigh {
        for x in 0..<pixelsWide {
            let at = (y * pixelsWide + x) * 4
            let (blue, green, red) = (Int(bgra[at]), Int(bgra[at + 1]), Int(bgra[at + 2]))
            if abs(red - green) > 1 || abs(red - blue) > 1 || abs(green - blue) > 1 {
                fail("the pixel \(x), \(y) is \(red), \(green), \(blue): smoothed by stripes")
            }
            let border = x == 0 || y == 0 || x == pixelsWide - 1 || y == pixelsHigh - 1
            if border && red != 255 {
                fail("the pixel \(x), \(y) on the border is \(red): a glyph is clipped")
            }
            values[y * pixelsWide + x] = UInt8(red)
        }
    }
    return values
}

/// The coverage of `bgra`, drawn in `text` over `ground`, row by row from
/// the top, 255 being full ink, checked: nothing drawn on the border, and
/// the three channels one coverage within 2 of 255.
func coverage(_ bgra: [UInt8], _ layout: Layout, text: RGB, ground: RGB, name: String)
    -> [UInt8]
{
    let (pixelsWide, pixelsHigh) = (layout.pixelsWide, layout.pixelsHigh)
    var values = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh)
    let pairs = [(2, ground.red, text.red), (1, ground.green, text.green), (0, ground.blue, text.blue)]
    for y in 0..<pixelsHigh {
        for x in 0..<pixelsWide {
            let at = (y * pixelsWide + x) * 4
            let each = pairs.map { (channel, under, over) -> Double in
                Double(Int(bgra[at + channel]) - under) / Double(over - under) * 255
            }
            let (least, most) = (each.min()!, each.max()!)
            if most - least > 2 {
                fail("\(name): the pixel \(x), \(y) is \(each) as coverages: smoothed by stripes")
            }
            let value = max(0, min(255, (each.reduce(0, +) / 3).rounded()))
            let border = x == 0 || y == 0 || x == pixelsWide - 1 || y == pixelsHigh - 1
            if border && value != 0 {
                fail("\(name): the pixel \(x), \(y) on the border is \(value): a glyph is clipped")
            }
            values[y * pixelsWide + x] = UInt8(value)
        }
    }
    return values
}

/// Writes `values`, one byte a pixel, as an 8-bit grayscale PNG file.
func write(_ values: [UInt8], _ layout: Layout, to path: String) {
    let grayInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
    guard let data = CFDataCreate(nil, values, values.count),
        let source = CGDataProvider(data: data),
        let image = CGImage(
            width: layout.pixelsWide, height: layout.pixelsHigh, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: layout.pixelsWide, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: grayInfo, provider: source, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        fail("cannot make the PNG file \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("cannot write \(path)")
    }
}

/// The lines of `positions.txt` for `line` in `font` at `scale`, with what
/// is printed of Core Text's advances beside the line's positions.
func positions(_ line: CTLine, _ font: CTFont, scale: CGFloat) -> [String] {
    var lines: [String] = []
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    for run in runs {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var places = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &places)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, count)
        for index in 0..<count {
            let x = places[index].x * scale
            let y = places[index].y * scale
            let advance = advances[index].width * scale
            lines.append("\(Int(scale)) \(glyphs[index]) \(x) \(y) \(advance)")
            if index + 1 < count {
                let step = (places[index + 1].x - places[index].x) * scale
                if abs(step - advance) > 1e-9 {
                    print(
                        "capture: at scale \(Int(scale)) glyph \(index) moves the pen \(step) px; its advance is \(advance) px"
                    )
                }
            }
        }
    }
    return lines
}

/// Writes `lines` to `path`, under a header naming `font`.
func writePositions(_ lines: [String], font: String, to path: String) {
    let header = [
        "# Core Text's positions of \"\(sentence)\" in \(font) at \(Int(points)) pt",
        "# <scale> <glyph id> <x px> <y px> <advance px>, from the line's origin",
    ]
    let text = (header + lines).joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(path): \(error)")
    }
}

/// The first face of the font file at `path`, from its bytes, at 14 points.
func firstFace(_ path: String) -> CTFont {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("cannot read \(path)")
    }
    guard
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
            as? [CTFontDescriptor],
        let first = descriptors.first
    else {
        fail("no face in \(path)")
    }
    return CTFontCreateWithFontDescriptor(first, points, nil)
}

let arguments = CommandLine.arguments
if arguments.count == 4 && arguments[1] == "--positions" {
    let (fontPath, outputPath) = (arguments[2], arguments[3])
    let font = firstFace(fontPath)
    let line = makeLine(font, black)
    let lines = positions(line, font, scale: 1) + positions(line, font, scale: 2)
    writePositions(lines, font: (fontPath as NSString).lastPathComponent, to: outputPath)
    print("capture: wrote \(outputPath): \(lines.count) glyph positions")
    exit(0)
}
guard arguments.count == 3 else {
    fail(
        "usage: capture.swift <font file> <directory to write in>, or capture.swift --positions <font file> <file to write>"
    )
}
let (fontPath, directory) = (arguments[1], arguments[2])

guard let provider = CGDataProvider(url: URL(fileURLWithPath: fontPath) as CFURL),
    let cgFont = CGFont(provider)
else {
    fail("cannot read a font from \(fontPath)")
}
let font = CTFontCreateWithGraphicsFont(cgFont, points, nil, nil)
func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

// The weight sentence, as it was captured on 2026-11-14.
let line = makeLine(font, black)
let large = Layout(line, scale: 2)
let smoothed = gray(draw(line, large, ground: white, smoothed: true), large)
let unsmoothed = gray(draw(line, large, ground: white, smoothed: false), large)
write(smoothed, large, to: path("sentence.png"))

/// How many values are below 128, and how far below 255 they are, summed.
func weigh(_ values: [UInt8]) -> (dark: Int, ink: Int) {
    (values.filter { $0 < 128 }.count, values.reduce(0) { $0 + 255 - Int($1) })
}

let (darkCount, ink) = weigh(smoothed)
let (plainDark, plainInk) = weigh(unsmoothed)
print("capture: wrote sentence.png: \(large.pixelsWide) by \(large.pixelsHigh) pixels, baseline \(large.baseline) up from the bottom")
print("capture: line \(large.width) pt wide, ascent \(large.ascent), descent \(large.descent)")
print("capture: smoothed: \(darkCount) dark pixels, ink \(ink)")
print("capture: not smoothed: \(plainDark) dark pixels, ink \(plainInk)")
print("capture: smoothing changes the drawing: \(smoothed != unsmoothed)")

// The drawings the rasteriser is also compared with.
let small = Layout(line, scale: 1)
for (name, layout, text, ground) in [
    ("sentence-dark.png", large, light, dark),
    ("sentence-14.png", small, black, white),
    ("sentence-14-dark.png", small, light, dark),
    ("sentence-grey.png", large, grey, white),
] {
    let drawn = draw(makeLine(font, text), layout, ground: ground, smoothed: true)
    let values = coverage(drawn, layout, text: text, ground: ground, name: name)
    write(values, layout, to: path(name))
    let total = values.reduce(0) { $0 + Int($1) }
    print("capture: wrote \(name): \(layout.pixelsWide) by \(layout.pixelsHigh) pixels, baseline \(layout.baseline) up from the bottom, coverage \(total)")
}

let lines = positions(line, font, scale: 1) + positions(line, font, scale: 2)
writePositions(lines, font: (fontPath as NSString).lastPathComponent, to: path("positions.txt"))
print("capture: wrote positions.txt: \(lines.count) glyph positions")
