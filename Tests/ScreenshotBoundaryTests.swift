// Sonuvi — GPL-3.0. Available width comes from observed obstacles, not text length.
import AppKit

@MainActor
func runScreenshotBoundaryChecks() -> Int {
    var checks = 0
    func check(_ value:Bool,_ message:String) {guard value else{fatalError("FAIL: "+message)};checks += 1}
    let size = CGSize(width:640,height:360)
    func norm(_ r:CGRect) -> CGRect {CGRect(x:r.minX/640,y:r.minY/360,width:r.width/640,height:r.height/360)}
    func region(_ width:CGFloat = 24,_ text:String = "设置") -> ScreenshotTextRegion {ScreenshotTextRegion(id:0,text:text,bounds:norm(CGRect(x:40,y:100,width:width,height:16)),lineHeight:16/360)}
    func image(_ draw:(CGContext)->Void = {_ in}) -> CGImage {
        let c = CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray:0.12,alpha:1));c.fill(CGRect(origin:.zero,size:size));draw(c);return c.makeImage()!
    }
    func constrained(_ image:CGImage,_ r:ScreenshotTextRegion? = nil,other:[ScreenshotTextRegion] = [],semantic:[ScreenshotVisualContainer] = []) -> ScreenshotTextRegion {
        ScreenshotVisualGeometry(image:image).constrain(ScreenshotDocument(regions:[r ?? region()]+other),semantic:semantic).regions[0]
    }
    func box(_ r:ScreenshotTextRegion) -> CGRect {ScreenshotLayout.rect(r.viewport!,in:size)}
    let blank = image(),short = constrained(blank),long = constrained(blank,region(72,"打开设置页面"))
    check(abs(box(short).maxX-638) < 0.1,"An unobstructed label uses space to the image edge")
    check(abs(box(short).maxX-box(long).maxX) < 0.1 && abs(box(short).width-box(long).width) < 0.1,"Changing original text length cannot change the available horizontal region")
    let p = ScreenshotLayout.placement(region:short,text:"Open the settings panel",regions:[short],size:size)
    check(p.fontSize >= 11.5 && !p.scrolls,"A longer translation retains source-scale type when actual free space is available")

    let border = image {c in c.setFillColor(CGColor(gray:0.19,alpha:1));c.fill(CGRect(x:300,y:92,width:1,height:30))}
    let a = constrained(border),b = constrained(border,region(72,"打开设置页面"))
    check(box(a).maxX >= 294 && box(a).maxX <= 300,"A short one-pixel edge beside the baseline stops expansion")
    check(abs(box(a).maxX-box(b).maxX) < 0.1,"The same border produces the same right boundary for short and long source strings")
    check(a.rightBoundaryKind == "pixel-edge","A local border is detected without requiring a full-height column separator")

    let neighbor = ScreenshotTextRegion(id:1,text:"Another label",bounds:norm(CGRect(x:240,y:100,width:90,height:16)),lineHeight:16/360)
    let textBound = constrained(blank,other:[neighbor])
    check(box(textBound).maxX >= 235 && box(textBound).maxX < 240,"The next text's near edge reserves the whole preceding blank gap")
    check(box(textBound).maxX > (64+240)/2+50,"Available width is not cut at the midpoint between two original strings")
    check(textBound.rightBoundaryKind == "text","Text collision works when no enclosing container is found")

    let control = image {c in c.setFillColor(CGColor(gray:0.26,alpha:1));c.fill(CGRect(x:220,y:94,width:90,height:30))}
    let nextControl = constrained(control)
    check(box(nextControl).maxX >= 214 && box(nextControl).maxX <= 220,"The nearest neighboring control stops expansion")
    let unrecognized = image {c in c.setStrokeColor(CGColor(gray:0.9,alpha:1));c.setLineWidth(2);c.strokeEllipse(in:CGRect(x:180,y:102,width:14,height:14))}
    let graphic = constrained(unrecognized)
    check(box(graphic).maxX >= 173 && box(graphic).maxX <= 180,"Unrecognized icon pixels also stop text before contact")

    let otherRow = ScreenshotTextRegion(id:1,text:"Different row",bounds:norm(CGRect(x:180,y:40,width:80,height:16)),lineHeight:16/360)
    check(abs(box(constrained(blank,other:[otherRow])).maxX-638) < 0.1,"A separate lower row does not incorrectly shorten horizontal clearance")
    let semantic = ScreenshotVisualContainer(bounds:norm(CGRect(x:25,y:90,width:270,height:40)),compact:true)
    check(box(constrained(blank,semantic:[semantic])).maxX <= 295,"An authoritative control boundary remains a hard stop")
    let tightHit = ScreenshotVisualContainer(bounds:norm(CGRect(x:38,y:98,width:28,height:20)),compact:true)
    check(box(constrained(border,semantic:[tightHit])).maxX >= 294,"A label-sized accessibility hit frame cannot replace the observed outer edge")
    let mixed = constrained(border,other:[neighbor])
    check(box(mixed).maxX < 240,"The closest real obstacle wins over a more distant border")
    let peers = [ScreenshotTextRegion(id:1,text:"Peer one",bounds:norm(CGRect(x:32,y:40,width:40,height:16)),lineHeight:16/360),ScreenshotTextRegion(id:2,text:"Peer two",bounds:norm(CGRect(x:24,y:160,width:56,height:16)),lineHeight:16/360)]
    let rail = ScreenshotVisualGeometry(image:blank).constrain(ScreenshotDocument(regions:[region()]+peers)).regions[0]
    let railPlacement = ScreenshotLayout.placement(region:rail,text:"Settings",regions:[rail],size:size)
    check(rail.centeredInViewport && abs(railPlacement.frame.maxY-116) <= 3,"Horizontal rail centering cannot move text vertically into blank space")
    let besideIcon = ScreenshotVisualGeometry(image:blank).constrain(ScreenshotDocument(regions:[region()]+peers,protectedBounds:[norm(CGRect(x:10,y:100,width:16,height:16))])).regions[0]
    check(!besideIcon.centeredInViewport && box(besideIcon).minX >= 38,"A left-aligned graphic row cannot be mistaken for a centered navigation rail")
    let leftPixels = image {c in c.setStrokeColor(CGColor(gray:0.9,alpha:1));c.setLineWidth(2);c.strokeEllipse(in:CGRect(x:10,y:100,width:16,height:16))}
    let unrecognizedLeft = ScreenshotVisualGeometry(image:leftPixels).constrain(ScreenshotDocument(regions:[region()]+peers)).regions[0]
    check(!unrecognizedLeft.centeredInViewport && box(unrecognizedLeft).minX >= 38,"Left icon pixels prevent recentering even when OCR recognizes no icon")
    var word = region();word.viewport = norm(CGRect(x:40,y:60,width:60,height:60))
    let whole = ScreenshotLayout.placement(region:word,text:"Preferences",regions:[word],size:size)
    let storage = NSTextStorage(string:"Preferences",attributes:[.font:NSFont.systemFont(ofSize:whole.fontSize)])
    let manager = NSLayoutManager(),container = NSTextContainer(size:CGSize(width:whole.frame.width-whole.textInset*2,height:1000))
    container.lineFragmentPadding = 0;storage.addLayoutManager(manager);manager.addTextContainer(container);manager.ensureLayout(for:container)
    var firstLine = NSRange();_ = manager.lineFragmentRect(forGlyphAt:0,effectiveRange:&firstLine)
    check(firstLine.length == manager.numberOfGlyphs,"A word that can fit through modest shrinking remains intact rather than splitting into letters")
    return checks
}
