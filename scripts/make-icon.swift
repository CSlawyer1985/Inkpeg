// Rasterize Inkpeg's own film/site mark: warm paper, silver clip and red rope.
// Geometry and colors come from site/assets/mark.svg (64 x 64), not upstream art.
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let pngOnly = destination.pathExtension.lowercased() == "png"
if !pngOnly { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
    if let stroke { stroke.setStroke(); path.lineWidth = width; path.stroke() }
}
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    if pngOnly && pixels != 1024 { continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    let mask = NSBezierPath(roundedRect: NSRect(x:96,y:96,width:832,height:832),xRadius:195,yRadius:195)
    color(0x17181c).setFill(); mask.fill(); mask.addClip()
    ctx.translateBy(x:96,y:928); ctx.scaleBy(x:13,y:-13)
    let rope = NSBezierPath(); rope.move(to:NSPoint(x:-2,y:17)); rope.curve(to:NSPoint(x:66,y:17),controlPoint1:NSPoint(x:20.666667,y:25),controlPoint2:NSPoint(x:43.333333,y:25)); rope.lineWidth=2.2; rope.lineCapStyle = .round; color(0x8d8f94).setStroke(); rope.stroke()
    let red = NSBezierPath(); red.move(to:NSPoint(x:39,y:21.6)); red.curve(to:NSPoint(x:48.5,y:19.2),controlPoint1:NSPoint(x:42.333333,y:20.933333),controlPoint2:NSPoint(x:45.5,y:20.133333)); red.lineWidth=3; red.lineCapStyle = .round; color(0xff3b30).setStroke(); red.stroke()
    ctx.translateBy(x:26,y:22); ctx.rotate(by:-6 * .pi / 180); ctx.translateBy(x:-26,y:-22)
    rounded(NSRect(x:12,y:25,width:28,height:30),5,color(0xf5f2ea))
    let text = NSBezierPath(); text.move(to:NSPoint(x:17,y:36)); text.line(to:NSPoint(x:35,y:36)); text.move(to:NSPoint(x:17,y:41)); text.line(to:NSPoint(x:35,y:41)); text.move(to:NSPoint(x:17,y:46)); text.line(to:NSPoint(x:28,y:46)); text.lineWidth=2.2; text.lineCapStyle = .round; color(0x17181c,0.38).setStroke(); text.stroke()
    rounded(NSRect(x:22.5,y:14,width:7,height:17),2.6,color(0xd9dbe0),stroke:color(0xffffff,0.7))
    rounded(NSRect(x:24,y:19.4,width:4,height:1.3),0.6,color(0x17181c,0.45))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:pngOnly ? destination : destination.appendingPathComponent("icon_\(name).png"))
}
