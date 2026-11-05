// Sonuvi — GPL-3.0. Anonymous outline-navigation regressions, without a provider.
import AppKit

let ScreenshotNavigationTranslations = ["Home":"首页","Explore":"探索","Notifications":"通知","Follow":"关注","Chat":"聊天","Calls":"通话","Grok":"Grok","Premium+":"Premium+","History":"历史记录","Profile":"个人资料","More":"更多","Post":"发帖"]
let ScreenshotNavigationLabels = ["Home","Explore","Notifications","Follow","Chat","Calls","Grok","Premium+","History","Profile","More"]

@MainActor
func makeScreenshotNavigationScene(scale:Int = 2,dark:Bool = false) -> CGImage {
    let size = CGSize(width:263,height:725),s = CGFloat(scale)
    let c = CGContext(data:nil,width:263*scale,height:725*scale,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x:s,y:s);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext:c,flipped:false)
    defer {NSGraphicsContext.restoreGraphicsState()}
    let bg = dark ? NSColor(white:0.09,alpha:1) : .white,fg = dark ? NSColor.white : NSColor(white:0.06,alpha:1)
    bg.setFill();NSBezierPath(rect:CGRect(origin:.zero,size:size)).fill()
    let symbols = ["house","magnifyingglass","bell","person.badge.plus","bubble","phone","circle.slash","checkmark.seal","bookmark","person","ellipsis.circle"]
    for (i,label) in ScreenshotNavigationLabels.enumerated() {
        let y = CGFloat(680-i*58)
        let symbol = NSImage(systemSymbolName:symbols[i],accessibilityDescription:nil)!.withSymbolConfiguration(.init(pointSize:24,weight:.regular))!
        let tinted = NSImage(size:NSSize(width:26,height:26),flipped:false) { rect in
            symbol.draw(in:rect);fg.setFill();rect.fill(using:.sourceAtop);return true
        }
        tinted.draw(in:CGRect(x:18,y:y-2,width:26,height:26))
        NSAttributedString(string:label,attributes:[.font:NSFont.systemFont(ofSize:20,weight:i == 1 ? .bold : .regular),.foregroundColor:fg]).draw(at:CGPoint(x:64,y:y))
    }
    fg.setFill();let button=CGRect(x:7,y:10,width:230,height:50);NSBezierPath(roundedRect:button,xRadius:25,yRadius:25).fill()
    NSAttributedString(string:"Post",attributes:[.font:NSFont.systemFont(ofSize:18,weight:.bold),.foregroundColor:bg]).draw(at:CGPoint(x:103,y:24))
    return c.makeImage()!
}

@MainActor
func runScreenshotNavigationChecks() async -> Int {
    var checks = 0
    func check(_ condition:Bool,_ message:String) {guard condition else {fatalError("FAIL: "+message)};checks += 1}
    for dark in [false,true] {for scale in [1,2] {
        let image = makeScreenshotNavigationScene(scale:scale,dark:dark),size=CGSize(width:263,height:725)
        try! NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/sonuvi-navigation-\(dark)-\(scale).png"))
        let document = try! await OCRService.recognizeDocument(.image(image),cpuOnly:true)
        let labels = document.regions.map(\.text)
        for label in ScreenshotNavigationLabels+["Post"] {
            check(labels.contains(label),"Outline navigation preserves the complete label: \(label), scale \(scale), dark \(dark); got \(labels)")
        }
        check(labels.count == 12,"No outline icon becomes a translated or copied text region")
        let values = Dictionary(uniqueKeysWithValues:document.regions.map {($0.id,ScreenshotNavigationTranslations[$0.text]!)})
        let placements = document.regions.filter {$0.text != "Post"}.map {ScreenshotLayout.placement(region:$0,text:values[$0.id]!,regions:document.regions,size:size)}
        check(placements.allSatisfy {!$0.scrolls && $0.frame.minX >= 61},"All navigation labels remain in the text column and fit")
        let fonts=placements.map(\.fontSize)
        check(fonts.max()!-fonts.min()! < 2,"Descenders and bold selection do not inflate individual navigation rows")
        let rendered = ScreenshotImageRenderer.render(image:image,size:size,document:document,values:values,original:false)!
        func pixels(_ image:CGImage,_ rect:CGRect) -> Data {
            let crop=CapturedDisplay(frame:CGRect(origin:.zero,size:size),image:image).crop(rect)!
            var data=[UInt8](repeating:0,count:crop.width*crop.height*4)
            data.withUnsafeMutableBytes {buffer in
                let c=CGContext(data:buffer.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
            }
            return Data(data)
        }
        for i in 0..<11 {
            let icon = CGRect(x:12,y:CGFloat(674-i*58),width:38,height:34)
            check(pixels(image,icon) == pixels(rendered,icon),"Full original outline icon pixels survive translation: row \(i)")
        }
        if scale == 2 && !dark {
            try! NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/sonuvi-navigation-original.png"))
            try! NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/sonuvi-navigation-translated.png"))
        }
    }}
    // A first column of ordinary letters beside descriptive text is not an icon
    // rail: every glyph has the same text height, with no larger outline evidence.
    let c=CGContext(data:nil,width:526,height:1450,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x:2,y:2);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
    NSColor.white.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:263,height:725)).fill()
    var lines:[ScreenshotTextLine]=[]
    for i in 0..<6 {
        let y=CGFloat(650-i*80)
        for (text,x) in [("A",CGFloat(20)),("more news",CGFloat(64))] {
            let a=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.black]);a.draw(at:CGPoint(x:x,y:y))
            lines.append(ScreenshotTextLine(text:text,bounds:CGRect(x:x/263,y:y/725,width:a.size().width/263,height:a.size().height/725),confidence:1))
        }
    }
    NSGraphicsContext.restoreGraphicsState();let geometry=ScreenshotVisualGeometry(image:c.makeImage()!),masks=geometry.graphics(for:lines)
    for line in lines where line.text == "A" {check(!masks.contains {$0.intersects(line.bounds)},"Repeated real letter values stay translatable in a left-hand table column")}
    return checks
}

@MainActor
func runScreenshotNavigationProviderTest() async {
    do {
        let image=makeScreenshotNavigationScene(),start=ProcessInfo.processInfo.systemUptime
        let document=try await OCRService.recognizeDocument(.image(image),cpuOnly:true)
        guard Set(document.regions.map(\.text)) == Set(ScreenshotNavigationLabels+["Post"]) else {throw TranslateError.message("Navigation OCR included an icon or damaged a label")}
        let recognized=ProcessInfo.processInfo.systemUptime
        // Headless acceptance must not open an OS authorization dialog.
        let key=try KeyStore.read(allowInteraction:false)
        let model=UserDefaults.standard.string(forKey:"modelName") ?? "deepseek-flash"
        let work=ScreenshotTranslationWork(document:document,direction:.toChinese)
        var requests=0
        try await work.run(send:{text,direction,update in
            requests += 1
            return try await DeepSeekClient.stream(DeepSeekClient.screenshotRequest(text:text,direction:direction,model:model,key:key),onDelta:update)
        },onUpdate:{_ in},onProgress:{_,_,_ in})
        guard work.completed.count == document.regions.count else {throw TranslateError.message("Incomplete navigation translation")}
        for region in document.regions where ["Home","Explore","Notifications","Profile"].contains(region.text) {
            guard let value=work.completed[region.id],value.unicodeScalars.contains(where:{(0x3400...0x9FFF).contains($0.value)}) else {throw TranslateError.message("Missing Chinese navigation label")}
        }
        guard let rendered=ScreenshotImageRenderer.render(image:image,size:CGSize(width:263,height:725),document:document,values:work.completed,original:false),let png=NSBitmapImageRep(cgImage:rendered).representation(using:.png,properties:[:]) else {throw TranslateError.message("Navigation export overflowed")}
        try png.write(to:URL(fileURLWithPath:"/tmp/sonuvi-navigation-live.png"))
        let report:[String:Any] = ["synthetic_only":true,"regions":document.regions.count,"requests":requests,"ocr_seconds":recognized-start,"translation_and_export_seconds":ProcessInfo.processInfo.systemUptime-recognized,"export_pixels":[rendered.width,rendered.height],"headless_keychain":true,"source_labels":document.regions.map(\.text)]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"/tmp/sonuvi-navigation-live.json"))
        print("PASS: live navigation translation; intact labels, no icon text, complete PNG export")
        exit(0)
    } catch {fputs("Navigation provider test failed: \(error.localizedDescription)\n",stderr);exit(1)}
}
