// Sonuvi — GPL-3.0. Geometry/containment regression checks, no provider required.
import AppKit
import ImageIO

@MainActor
func runScreenshotContainerInspection() async {
    do {
        let args = CommandLine.arguments,index = args.firstIndex(of:"--screenshot-container-inspect")!
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath:args[index+1]) as CFURL,nil)!,0,nil)!
        let output = URL(fileURLWithPath:args[index+2],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let start = ProcessInfo.processInfo.systemUptime,doc = try await OCRService.recognizeDocument(.image(image),cpuOnly:true)
        let size = CGSize(width:CGFloat(image.width)/2,height:CGFloat(image.height)/2)
        let translations:[String:String] = ["输入":"Input","点语":"Tap to speak","搜索页面":"Search page","工作区":"Workspace","历史":"History","个人词表":"Personal word list","统计":"Statistics","偏好设置":"Preferences","通用":"General","录音":"Recording","快捷键":"Shortcuts","权限":"Permissions","模型":"Model","关于":"About","开始听写":"Start dictation","直接出英文":"Output English directly","不整理":"No organization","轻整理":"Light organization","结构化整理":"Structured organization","管理词表":"Manage word list","最终结果":"Final result","原始识别":"Original recognition","整理结果":"Organized results","复制":"Copy","重新处理":"Reprocess","语音输入":"Voice input","整理程度":"Cleanup level","最近结果":"Recent results","识别模型已就绪":"Recognition model ready","版本 0.1.7":"Version 0.1.7","完全本地":"Fully local","听写 右侧 Option":"Dictation: Right Option","翻译":"Translate","处理 1.79秒":"Process: 1.79 s","10 个启用词条将参与下一次识别":"10 enabled terms will be used in the next recognition.","听写":"Dictation","右侧":"Right","翻译 ^":"Translate ^","处理":"Process","1.79秒":"1.79 s","想法，说出来。":"Say your thoughts out loud.","随时开始一段听写":"Start dictating anytime","用自己的话，把想法自然说出来。":"Say your ideas naturally, in your own words.","在本机识别、整理，再写入当前应用。":"Recognized and organized on this device, then written into the current app.","文本整理自测（不计入输入统计）":"Text cleanup self-test (excluded from statistics)"]
        var values:[Int:String] = [:],reports:[[String:Any]] = [],overflow = 0,escaped = 0
        for region in doc.regions {
            let key = region.text.trimmingCharacters(in:.whitespacesAndNewlines)
            let value = translations[key] ?? (TextRules.direction(key) == .toEnglish ? (key.count > 12 ? "Text is recognized and organized on this device, then written into the current application." : "Translated content") : key)
            values[region.id] = value
            let p = ScreenshotLayout.placement(region:region,text:value,regions:doc.regions,size:size,protectedBounds:doc.protectedBounds)
            if p.scrolls {overflow += 1}
            let viewport = ScreenshotLayout.rect(region.viewport!,in:size)
            if !viewport.insetBy(dx:-0.01,dy:-0.01).contains(p.frame) {escaped += 1}
            reports.append(["source":key,"value":value,"source_box":NSStringFromRect(ScreenshotLayout.rect(region.bounds,in:size)),"viewport":NSStringFromRect(viewport),"frame":NSStringFromRect(p.frame),"font":p.fontSize,"overflow":p.scrolls])
        }
        let canvas = ScreenshotCanvasView(image:image,size:size);_ = canvas.update(document:doc,values:values,original:false)
        if let bitmap = canvas.bitmapImageRepForCachingDisplay(in:canvas.bounds) {canvas.cacheDisplay(in:canvas.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("native-preset.png"))}
        if let export = ScreenshotImageRenderer.render(image:image,size:size,document:doc,values:values,original:false) {try NSBitmapImageRep(cgImage:export).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("export-preset.png"))}
        let result:[String:Any] = ["local_only":true,"preset_translations":true,"network_requests":0,"pixels":[image.width,image.height],"regions":reports,"protected":doc.protectedBounds.map {NSStringFromRect(ScreenshotLayout.rect($0,in:size))},"overflow_regions":overflow,"escaped_regions":escaped,"seconds":ProcessInfo.processInfo.systemUptime-start]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("inspection.json"))
        print("Local preset inspection: regions=\(reports.count), overflow=\(overflow), escaped=\(escaped)");exit(0)
    } catch {fputs("Container inspection failed: \(error.localizedDescription)\n",stderr);exit(1)}
}

@MainActor
func runScreenshotContainerChecks() -> Int {
    var checks = 0
    func check(_ value:Bool,_ message:String) {guard value else{fatalError("FAIL: "+message)};checks += 1}
    let size = CGSize(width:640,height:360)
    let context = CGContext(data:nil,width:1280,height:720,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x:2,y:2);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
    NSColor(white:0.12,alpha:1).setFill();NSBezierPath(rect:CGRect(origin:.zero,size:size)).fill()
    let button = CGRect(x:60,y:250,width:150,height:36),group = CGRect(x:280,y:250,width:300,height:36),selected = CGRect(x:382,y:253,width:96,height:30)
    NSColor(white:0.23,alpha:1).setFill();NSBezierPath(roundedRect:button,xRadius:7,yRadius:7).fill();NSBezierPath(roundedRect:group,xRadius:7,yRadius:7).fill()
    NSColor(white:0.36,alpha:1).setFill();NSBezierPath(roundedRect:selected,xRadius:5,yRadius:5).fill()
    NSColor.systemPurple.setFill();NSBezierPath(roundedRect:CGRect(x:70,y:257,width:22,height:22),xRadius:4,yRadius:4).fill()
    let boxes = [CGRect(x:105,y:260,width:45,height:16),CGRect(x:303,y:260,width:45,height:16),CGRect(x:406,y:260,width:45,height:16),CGRect(x:503,y:260,width:45,height:16)]
    for box in boxes {NSAttributedString(string:"测试区",attributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.white]).draw(at:box.origin)}
    var navigation:[ScreenshotTextLine] = [],plain:[ScreenshotTextLine] = []
    for i in 0..<4 {
        let y = CGFloat(50+i*42),tile = CGRect(x:70,y:y,width:22,height:22)
        NSGradient(starting:NSColor(srgbRed:0.5,green:0.3,blue:0.55,alpha:1),ending:NSColor(srgbRed:0.43,green:0.32,blue:0.48,alpha:1))!.draw(in:NSBezierPath(roundedRect:tile,xRadius:4,yRadius:4),angle:35)
        let glyph = CGRect(x:73,y:y+3,width:16,height:16),label = CGRect(x:105,y:y+3,width:45,height:16)
        navigation += [ScreenshotTextLine(text:"Back",bounds:CGRect(x:glyph.minX/640,y:glyph.minY/360,width:glyph.width/640,height:glyph.height/360),confidence:1),ScreenshotTextLine(text:"条目文字",bounds:CGRect(x:label.minX/640,y:label.minY/360,width:label.width/640,height:label.height/360),confidence:1)]
        plain += [ScreenshotTextLine(text:"A",bounds:CGRect(x:400/640,y:glyph.minY/360,width:16/640,height:16/360),confidence:1),ScreenshotTextLine(text:"Plain value",bounds:CGRect(x:435/640,y:label.minY/360,width:90/640,height:16/360),confidence:1)]
        NSAttributedString(string:"A",attributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.systemBlue]).draw(at:CGPoint(x:400,y:y+3))
    }
    NSGraphicsContext.restoreGraphicsState();let image = context.makeImage()!,geometry = ScreenshotVisualGeometry(image:image)
    func normalized(_ r:CGRect) -> CGRect {CGRect(x:r.minX/size.width,y:r.minY/size.height,width:r.width/size.width,height:r.height/size.height)}
    let icons = [normalized(CGRect(x:70,y:257,width:22,height:22))]
    let raw = ScreenshotDocument(regions:boxes.enumerated().map {ScreenshotTextRegion(id:$0.offset,text:"测试区",bounds:normalized($0.element),lineHeight:16/360)},protectedBounds:icons)
    let doc = geometry.constrain(raw)
    check(geometry.containers.filter(\.segment).count >= 3,"Selected chip supplies three independent cell boundaries")
    let phrases = ["Output English directly","No organization","Light organization","Structured organization"]
    for scale in [CGFloat(0.75),1,1.5] {
        let display = CGSize(width:size.width*scale,height:size.height*scale)
        for region in doc.regions {
            let p = ScreenshotLayout.placement(region:region,text:phrases[region.id],regions:doc.regions,size:display,protectedBounds:icons)
            let control = region.id == 0 ? button : CGRect(x:283+CGFloat(region.id-1)*98,y:253,width:98,height:30)
            check(CGRect(x:control.minX*scale,y:control.minY*scale,width:control.width*scale,height:control.height*scale).contains(p.frame),"Translations stay inside the actual button or segmented cell at multiple display scales")
            check(!p.scrolls,"Ordinary long control translations fit through measured shrinking or wrapping")
            if region.id == 0 {check(p.frame.minX >= 92*scale,"The icon's slot is excluded from label layout")}
        }
    }
    let long = ScreenshotLayout.placement(region:doc.regions[0],text:String(repeating:"Extremely long translation. ",count:80),regions:doc.regions,size:size)
    check(long.scrolls && button.contains(long.frame),"Impossible content remains clipped inside its control, with full copyable text retained")
    let navMasks = geometry.graphics(for:navigation+plain)
    for glyph in navigation where glyph.text == "Back" {check(navMasks.contains {$0.contains(CGPoint(x:glyph.bounds.midX,y:glyph.bounds.midY))},"Gradient icon tiles are protected by their graphic column, regardless of OCR word")}
    for value in plain where value.text == "A" {check(!navMasks.contains {$0.contains(CGPoint(x:value.bounds.midX,y:value.bounds.midY))},"Plain repeated text columns are retained without a graphic tile")}
    let marks = geometry.graphics(for:[ScreenshotTextLine(text:"word",bounds:normalized(CGRect(x:73,y:260,width:16,height:16)),confidence:1)])
    check(marks.contains {$0.intersects(icons[0])},"A colored icon remains protected even when OCR calls it an ordinary word")
    let values = Dictionary(uniqueKeysWithValues:doc.regions.map {($0.id,phrases[$0.id])})
    let rendered = ScreenshotImageRenderer.render(image:image,size:size,document:doc,values:values,original:false)!
    func pixels(_ image:CGImage,_ rect:CGRect) -> Data {
        let crop = CapturedDisplay(frame:CGRect(origin:.zero,size:size),image:image).crop(rect)!
        var bytes = [UInt8](repeating:0,count:crop.width*crop.height*4)
        bytes.withUnsafeMutableBytes {buffer in
            let context = CGContext(data:buffer.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
        }
        return Data(bytes)
    }
    check(pixels(image,CGRect(x:70,y:257,width:22,height:22)) == pixels(rendered,CGRect(x:70,y:257,width:22,height:22)),"Original icon pixels survive erasure, text rendering and export")
    for box in [button,group] {
        for edge in [CGRect(x:box.minX,y:box.minY,width:box.width,height:1),CGRect(x:box.minX,y:box.maxY-1,width:box.width,height:1)] {
            check(pixels(image,edge) == pixels(rendered,edge),"Top and bottom control borders remain pixel-identical after translation")
        }
    }
    let canvas = ScreenshotCanvasView(image:image,size:size);_ = canvas.update(document:doc,values:values,original:false)
    check(canvas.subviews.compactMap {$0 as? NSScrollView}.allSatisfy {$0.layer?.masksToBounds == true},"Native selectable text is clipped to its control viewport")
    return checks
}
