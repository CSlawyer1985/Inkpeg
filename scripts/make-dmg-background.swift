// Inkpeg DMG instructions, typeset with the same original product branding.
import AppKit
let out = CommandLine.arguments[1]
let scale: CGFloat = 2
let W: CGFloat = 720, H: CGFloat = 560
func color(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((hex>>16)&255)/255, green: CGFloat((hex>>8)&255)/255, blue: CGFloat(hex&255)/255, alpha: 1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*scale), pixelsHigh: Int(H*scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W,height: H)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// NSGraphicsContext already uses rep.size to scale the 2x bitmap.
color(0xf4f1e9).setFill();NSRect(x:0,y:0,width:W,height:H).fill()
func text(_ value: String,_ x: CGFloat,_ top: CGFloat,_ width: CGFloat,_ size: CGFloat,_ weight: NSFont.Weight = .regular,_ ink: UInt32 = 0x24252a) {
    let style=NSMutableParagraphStyle();style.lineSpacing=4
    NSAttributedString(string:value,attributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color(ink),.paragraphStyle:style]).draw(in:NSRect(x:x,y:H-top-64,width:width,height:64))
}
if let logo=NSImage(contentsOfFile:"packaging/brand/Inkpeg.iconset/icon_128x128@2x.png") { logo.draw(in:NSRect(x:38,y:H-94,width:60,height:60)) }
text("文夹 Inkpeg",110,32,560,28,.semibold)
text("安装并开始试用",110,75,560,16,.medium,0x64615a)
text("双击下方安装助手 · 三步完成首次打开",44,121,640,18,.semibold)
// Finder icons occupy y=205 and labels below. Do not draw over them.
let box=NSBezierPath(roundedRect:NSRect(x:34,y:36,width:652,height:232),xRadius:12,yRadius:12);color(0xe9e5db).setFill();box.fill()
text("①  双击“安装文夹.command”",54,312,620,18,.semibold)
text("②  若被拦截：系统设置 → 隐私与安全性",54,352,620,18,.medium)
text("③  点击“仍要打开”，再按系统提示确认“打开”",54,392,620,18,.semibold,0xa34332)
text("安装完成：鼠标移到屏幕顶部，或按 Control＋Option＋T。",54,449,620,15)
text("拖入“应用程序”后首次打开，也需要按②③允许。",54,490,620,13,.regular,0x64615a)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:out))
