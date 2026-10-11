// Inkpeg's original rope/paper/red-clip mark, ported exactly from site/assets/mark.svg.
// Usage: swift scripts/make-icon.swift <new iconset directory | output.png>
import AppKit
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let pngOnly = destination.pathExtension.lowercased() == "png"
if !pngOnly { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
func color(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    if pngOnly && pixels != 1024 { continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let ctx=NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    color(0xf7f7f2).setFill(); NSBezierPath(roundedRect:NSRect(x:96,y:96,width:832,height:832),xRadius:186,yRadius:186).fill()
    ctx.translateBy(x:112,y:912); ctx.scaleBy(x:20,y:-20)
    let rope=NSBezierPath(); rope.move(to:NSPoint(x:3,y:13)); rope.curve(to:NSPoint(x:37,y:13),controlPoint1:NSPoint(x:14.333333,y:17.666667),controlPoint2:NSPoint(x:25.666667,y:17.666667)); rope.lineWidth=2; color(0x77796d).setStroke(); rope.stroke()
    let paper=NSBezierPath(); paper.move(to:NSPoint(x:12,y:16)); paper.line(to:NSPoint(x:12,y:32)); paper.line(to:NSPoint(x:28,y:29)); paper.line(to:NSPoint(x:28,y:16)); color(0xefeee5).setFill(); paper.fill(); color(0x747969).setStroke(); paper.lineWidth=1.5; paper.stroke()
    let clip=NSBezierPath(rect:NSRect(x:17,y:9,width:7,height:14)); color(0xb94f3b).setFill(); clip.fill(); color(0x9b3f2e).setStroke(); clip.lineWidth=1.5; clip.stroke()
    let highlight=NSBezierPath(); highlight.move(to:NSPoint(x:20.5,y:11)); highlight.line(to:NSPoint(x:20.5,y:20)); highlight.lineWidth=1.5; color(0xefc8b7).setStroke(); highlight.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:pngOnly ? destination : destination.appendingPathComponent("icon_\(name).png"))
}
