// Draws the sentence "the window draws this" with Core Text, as macOS draws
// it, and writes the drawing as a fixture.
//
//   swift tools/coretext/capture.swift <font file> <PNG file to write>
//
// Run by hand, on macOS, through `mise run coretext-reference`; never by the
// gate, which needs only the file checked in. tests/coretext/README.md says
// what the file is, how it was last captured and when to capture it again.
//
// The font is loaded from the bytes of the file given: nothing is installed
// or registered on the system. The sentence is drawn at 14 points on a
// bitmap scaled by 2, as TextEdit draws 14 pt on a display of scale 2, in
// black on a white ground, with font smoothing on and the baseline on a
// whole pixel. The bitmap is 8-bit RGB in the sRGB colour space: Core Text
// smooths only in an RGB context. Subpixel positioning and quantisation are
// left at the context's defaults, which CoreGraphics gives no way to read.
//
// Before it writes, it checks that no glyph reaches the bitmap's border and
// that red, green and blue agree within 1 at every pixel: smoothing on
// macOS is not by colour stripes, and if it were the script would refuse
// rather than pick a channel. It then writes the red channel as it is, as
// an 8-bit grayscale PNG file.
//
// It prints the bitmap's size and, for the drawing written and for a second
// drawing with smoothing off, the two counts the renderer's test makes:
// how many pixels are darker than mid-grey (below 128), and the ink, how
// far below the white ground the pixels are, summed. The second drawing is
// for a person, to show what smoothing does, and is not written.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sentence = "the window draws this"
let points: CGFloat = 14
let scale: CGFloat = 2
// The margin around the line, in pixels.
let margin = 16

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("capture: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: capture.swift <font file> <PNG file to write>")
}
let (fontPath, outputPath) = (arguments[1], arguments[2])

guard let provider = CGDataProvider(url: URL(fileURLWithPath: fontPath) as CFURL),
    let cgFont = CGFont(provider)
else {
    fail("cannot read a font from \(fontPath)")
}
let font = CTFontCreateWithGraphicsFont(cgFont, points, nil, nil)
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
]
let line = CTLineCreateWithAttributedString(
    NSAttributedString(string: sentence, attributes: attributes))

var ascent: CGFloat = 0
var descent: CGFloat = 0
var leading: CGFloat = 0
let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
let pixelsWide = Int((width * scale).rounded(.up)) + 2 * margin
let above = Int((ascent * scale).rounded(.up))
let below = Int((descent * scale).rounded(.up))
let pixelsHigh = above + below + 2 * margin
// The baseline, in pixels from the bottom: a whole pixel.
let baseline = margin + below

/// The bitmap of the sentence drawn with font smoothing on or off, as
/// bytes in memory order blue, green, red, alpha.
func draw(smoothed: Bool) -> [UInt8] {
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
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(smoothed)
    context.scaleBy(x: scale, y: scale)
    context.textPosition = CGPoint(x: CGFloat(margin) / scale, y: CGFloat(baseline) / scale)
    CTLineDraw(line, context)
    let bytes = context.data!.bindMemory(to: UInt8.self, capacity: pixelsWide * pixelsHigh * 4)
    return Array(UnsafeBufferPointer(start: bytes, count: pixelsWide * pixelsHigh * 4))
}

/// The red channel of `bgra`, row by row from the top, checked: nothing
/// drawn on the border, and the three channels alike.
func gray(_ bgra: [UInt8]) -> [UInt8] {
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

/// How many values are below 128, and how far below 255 they are, summed.
func weigh(_ values: [UInt8]) -> (dark: Int, ink: Int) {
    (values.filter { $0 < 128 }.count, values.reduce(0) { $0 + 255 - Int($1) })
}

let smoothed = gray(draw(smoothed: true))
let unsmoothed = gray(draw(smoothed: false))

let grayInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
guard let data = CFDataCreate(nil, smoothed, smoothed.count),
    let source = CGDataProvider(data: data),
    let image = CGImage(
        width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: pixelsWide, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: grayInfo,
        provider: source, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    fail("cannot make the PNG file \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("cannot write \(outputPath)")
}

let (dark, ink) = weigh(smoothed)
let (plainDark, plainInk) = weigh(unsmoothed)
print("capture: wrote \(outputPath): \(pixelsWide) by \(pixelsHigh) pixels, baseline \(baseline) up from the bottom")
print("capture: line \(width) pt wide, ascent \(ascent), descent \(descent)")
print("capture: smoothed: \(dark) dark pixels, ink \(ink)")
print("capture: not smoothed: \(plainDark) dark pixels, ink \(plainInk)")
print("capture: smoothing changes the drawing: \(smoothed != unsmoothed)")
