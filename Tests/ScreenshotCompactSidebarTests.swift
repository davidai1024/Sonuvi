// Sonuvi — GPL-3.0. Compact Chinese navigation, local pixels and preset output only.
import AppKit

let ScreenshotCompactSidebarLabels = ["我的主页","我的关注","我的粉丝","我的经常访问","我的收藏","我的赞","创作者中心"]
let ScreenshotCompactSidebarTranslations = ["我的主页":"My Homepage","我的关注":"My Following","我的粉丝":"My Followers","我的经常访问":"My Frequent Visits","我的收藏":"My Favorites","我的赞":"My Likes","创作者中心":"Creator Center"]

@MainActor
func makeScreenshotCompactSidebarScene(scale:Int = 2,dark:Bool = false) -> CGImage {
    let c=CGContext(data:nil,width:176*scale,height:285*scale,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x:CGFloat(scale),y:CGFloat(scale));NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
    defer {NSGraphicsContext.restoreGraphicsState()}
    (dark ? NSColor(white:0.08,alpha:1) : .white).setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:176,height:285)).fill()
    let symbols=["person","person.badge.checkmark","person.2","person.crop.circle.badge.clock","star","hand.thumbsup","gearshape"]
    for (i,label) in ScreenshotCompactSidebarLabels.enumerated() {
        let y=CGFloat(253-i*40),ink=i == 0 ? NSColor.systemOrange : NSColor(white:dark ? 0.75 : 0.5,alpha:1)
        let base=NSImage(systemSymbolName:symbols[i],accessibilityDescription:nil) ?? NSImage(systemSymbolName:"person",accessibilityDescription:nil)!
        let symbol=base.withSymbolConfiguration(.init(pointSize:22,weight:.regular)) ?? base
        let tinted=NSImage(size:NSSize(width:22,height:22),flipped:false) {r in symbol.draw(in:r);ink.setFill();r.fill(using:.sourceAtop);return true}
        tinted.draw(in:CGRect(x:18,y:y-1,width:22,height:22))
        NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:i == 0 ? .systemOrange : NSColor(white:dark ? 0.85 : 0.22,alpha:1)]).draw(at:CGPoint(x:46,y:y))
    }
    return c.makeImage()!
}

@MainActor
func runScreenshotCompactSidebarChecks() async -> Int {
    var checks=0
    func check(_ value:Bool,_ message:String) {guard value else {fatalError("FAIL: "+message)};checks += 1}
    for dark in [false,true] {for scale in [1,2,3] {
        let image=makeScreenshotCompactSidebarScene(scale:scale,dark:dark),size=CGSize(width:176,height:285)
        let document=try! await OCRService.recognizeDocument(.image(image),cpuOnly:true)
        let observed=document.regions.map(\.text)
        for label in ScreenshotCompactSidebarLabels {check(observed.contains(label),"Compact sidebar retains complete source label \(label), scale \(scale), dark \(dark); got \(observed)")}
        check(document.regions.count==7,"Compact icon slots never become translated or copied words")
        let values=Dictionary(uniqueKeysWithValues:document.regions.map {($0.id,ScreenshotCompactSidebarTranslations[$0.text]!)})
        for region in document.regions {
            let p=ScreenshotLayout.placement(region:region,text:values[region.id]!,regions:document.regions,size:size)
            check(!p.scrolls && p.frame.minX >= 44,"Compact labels fit in their actual text column")
            let storage=NSTextStorage(string:values[region.id]!,attributes:[.font:NSFont.systemFont(ofSize:p.fontSize)])
            let manager=NSLayoutManager(),container=NSTextContainer(size:CGSize(width:p.frame.width-2*p.textInset,height:1000));container.lineFragmentPadding=0
            storage.addLayoutManager(manager);manager.addTextContainer(container);manager.ensureLayout(for:container)
            var lines=0;manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) {_,_,_,_,_ in lines += 1}
            check(lines==1,"Short sidebar translations use available width before wrapping: \(region.text)")
        }
        let rendered=ScreenshotImageRenderer.render(image:image,size:size,document:document,values:values,original:false)!
        func bytes(_ image:CGImage) -> Data {
            let crop=CapturedDisplay(frame:CGRect(origin:.zero,size:size),image:image).crop(CGRect(x:0,y:0,width:44,height:285))!
            var b=[UInt8](repeating:0,count:crop.width*crop.height*4)
            b.withUnsafeMutableBytes {buffer in let c=CGContext(data:buffer.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))}
            return Data(b)
        }
        check(bytes(image)==bytes(rendered),"Every compact outline icon remains pixel-identical, including the gear")
        if scale==2 && !dark {
            try! NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/sonuvi-compact-sidebar-original.png"))
            try! NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/sonuvi-compact-sidebar-preset.png"))
        }
    }}
    return checks
}
