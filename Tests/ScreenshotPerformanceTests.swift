// Sonuvi — GPL-3.0. Performance tests send synthetic text only, never a user screenshot.
import AppKit
import Vision

let ScreenshotDarkTranslations = ["Search for documents and tips":"搜索文档和技巧","Search for documents and tips...":"搜索文档和技巧…","Recent":"最近","All Types":"所有类型","All Locations":"所有位置","Creator":"创建者","Last Modified":"最后修改","New":"新建","Open":"打开","Starred":"已加星标","Shared":"已共享","Cloud Document":"云文档","Personal Space":"个人空间","Team Space":"团队空间","My Devices":"我的设备","Label":"标签","Recycle Bin":"回收站","Local":"本地","Desktop":"桌面","Documents":"文档","Downloads":"下载","Browse":"浏览","Messages":"消息","Email":"邮件","Calendar":"日历","Templates":"模板","Today":"今天","Yesterday":"昨天","Me":"我","Guest":"访客"]

func screenshotDarkTranslation(_ text:String) -> String? {
    func normalized(_ value:String) -> String { value.lowercased().trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters)).replacingOccurrences(of:" ",with:"") }
    return ScreenshotDarkTranslations.first { normalized($0.key) == normalized(text) }?.value
}

@MainActor
func runScreenshotPerformanceTest() async {
    do {
        let image = makeScreenshotWorkspaceScene(diagram:false)
        let t0 = ProcessInfo.processInfo.systemUptime
        let document = try await OCRService.recognizeDocument(.image(image))
        let ocr = ProcessInfo.processInfo.systemUptime-t0
        let model = ScreenshotOverlayModel();model.document = document
        let direction = model.resolvedTarget.direction!
        let key = try KeyStore.read(allowInteraction:true)
        let name = UserDefaults.standard.string(forKey:"modelName") ?? "deepseek-flash"
        var trials: [[String:Any]] = []
        var latest: [Int:String] = [:]
        // Alternate order to avoid giving all connection/model warm-up to one mode.
        for concurrency in [1,3,3,1] {
            let work = ScreenshotTranslationWork(document:document,direction:direction,concurrency:concurrency,batchLimit:concurrency == 1 ? 8 : 12)
            let canvas = ScreenshotCanvasView(image:image,size:CGSize(width:1040,height:650))
            let start = ProcessInfo.processInfo.systemUptime
            var requests = 0,firstToken: TimeInterval?,firstCommit: TimeInterval?
            try await work.run(send: { input,target,delta in
                requests += 1
                let req = try DeepSeekClient.screenshotRequest(text:input,direction:target,model:name,key:key)
                return try await DeepSeekClient.stream(req,configuration:concurrency == 1 ? URLSessionConfiguration.ephemeral : nil) { value in
                    if firstToken == nil { firstToken = ProcessInfo.processInfo.systemUptime-start }
                    delta(value)
                }
            },onUpdate:{ _ in },onProgress:{ _,_,_ in },onCommit:{ values in
                if concurrency > 1,document.regions.contains(where:{values[$0.id] != nil && values[$0.id] != $0.text}) {
                    _ = canvas.update(document:document,values:values,original:false)
                    if firstCommit == nil { firstCommit = ProcessInfo.processInfo.systemUptime-start }
                }
            })
            if concurrency == 1 { _ = canvas.update(document:document,values:work.completed,original:false) }
            let full = ProcessInfo.processInfo.systemUptime-start
            guard work.completed.count == document.regions.count else { throw TranslateError.message("Incomplete performance fixture") }
            let trial: [String:Any] = ["concurrency":concurrency,"requests":requests,"first_token_seconds":firstToken ?? full,"first_visible_seconds":concurrency == 1 ? full : firstCommit ?? full,"full_seconds":full]
            trials.append(trial);latest = work.completed
            let json = try JSONSerialization.data(withJSONObject:trial,options:[.sortedKeys]);print(String(data:json,encoding:.utf8)!);fflush(stdout)
        }
        let cache = ScreenshotTranslationCache()
        cache.store(document:document,values:latest,model:name,direction:direction)
        let warmStart = ProcessInfo.processInfo.systemUptime
        let warmDocument = try await OCRService.recognizeDocument(.image(image))
        let cached = ScreenshotTranslationWork(document:warmDocument,direction:direction,cache:cache.values(document:warmDocument,model:name,direction:direction))
        var warmRequests = 0
        try await cached.run(send:{ value,_,_ in warmRequests += 1;return value },onUpdate:{ _ in },onProgress:{ _,_,_ in })
        guard warmRequests == 0 else { throw TranslateError.message("Screenshot cache missed identical source") }
        let warmCanvas = ScreenshotCanvasView(image:image,size:CGSize(width:1040,height:650))
        _ = warmCanvas.update(document:warmDocument,values:cached.completed,original:false)
        let warm = ProcessInfo.processInfo.systemUptime-warmStart
        let renderStart = ProcessInfo.processInfo.systemUptime
        guard let png = ScreenshotImageRenderer.render(image:image,size:CGSize(width:1040,height:650),document:document,values:latest,original:false).flatMap({NSBitmapImageRep(cgImage:$0).representation(using:.png,properties:[:])}) else { throw TranslateError.message("Performance fixture image overflow") }
        let render = ProcessInfo.processInfo.systemUptime-renderStart
        try png.write(to:URL(fileURLWithPath:"/tmp/sonuvi-speed-result.png"))
        let result: [String:Any] = ["synthetic_only":true,"ocr_seconds":ocr,"trials":trials,"warm_total_seconds":warm,"warm_requests":warmRequests,"render_seconds":render,"regions":document.regions.count]
        let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:"/tmp/sonuvi-speed-result.json"))
        print("PASS: measured OCR, serial and concurrent translation, first visible result, cache and Retina export")
        exit(0)
    } catch { fputs("Screenshot performance test failed: \(error.localizedDescription)\n",stderr);exit(1) }
}

@MainActor
func runScreenshotLocalInspection() async {
    do {
        guard let index = CommandLine.arguments.firstIndex(of:"--screenshot-local-inspect"), index+1 < CommandLine.arguments.count else { throw TranslateError.message("Missing local image path") }
        let url = URL(fileURLWithPath:CommandLine.arguments[index+1]),start = ProcessInfo.processInfo.systemUptime
        guard let image = NSImage(contentsOf:url) else { throw TranslateError.message("Local image cannot be opened") }
        var proposed = CGRect(origin:.zero,size:image.size)
        guard let cg = image.cgImage(forProposedRect:&proposed,context:nil,hints:nil) else { throw TranslateError.message("Local image cannot be decoded") }
        var reports: [[String:Any]] = []
        for _ in 0..<1 {
            let stages = ScreenshotTimingCollector()
            let run = ProcessInfo.processInfo.systemUptime
            let doc = try await OCRService.recognizeDocument(.image(cg),timing:{ stages.set($0) })
            let logical = CGSize(width:CGFloat(cg.width)/2,height:CGFloat(cg.height)/2)
            let labels = doc.regions.filter { ScreenshotTextFilter.isUILabel($0.text) }.map { region -> [String:Any] in
                let p = ScreenshotLayout.placement(region:region,text:ScreenshotDarkTranslations[region.text] ?? region.text,regions:doc.regions,size:logical,protectedBounds:doc.protectedBounds)
                return ["label":region.text,"font_points":p.fontSize,"bounds":[region.bounds.minX,region.bounds.minY,region.bounds.width,region.bounds.height]]
            }
            reports.append(["maximum_ocr_dimension":max(cg.width,cg.height),"seconds":ProcessInfo.processInfo.systemUptime-run,"regions":doc.regions.count,"protected_icons":doc.protectedBounds.count,"generic_ui_labels":labels,"stages":stages.values])
        }
        let result: [String:Any] = ["local_only":true,"network_requests":0,"pixels":[cg.width,cg.height],"seconds":ProcessInfo.processInfo.systemUptime-start,"reports":reports]
        let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);print(String(data:data,encoding:.utf8)!);exit(0)
    } catch { fputs("Local screenshot inspection failed: \(error.localizedDescription)\n",stderr);exit(1) }
}

@MainActor
func runScreenshotSpeedAndDarkChecks() async -> Int {
    var checks = 0
    func check(_ value:Bool,_ message:String) { guard value else { fatalError("FAIL: "+message) }; checks += 1 }
    func document(_ text:String) -> ScreenshotDocument { ScreenshotDocument(regions:[ScreenshotTextRegion(id:0,text:text,bounds:.zero,lineHeight:0.02)]) }
    let stopped = ScreenshotOCRCancellation();stopped.cancel()
    do { try stopped.register(VNRecognizeTextRequest());fatalError("OCR cancellation ignored") } catch {check(true,"Canceled OCR cannot register another recognition request")}
    let many = ScreenshotDocument(regions:(0..<40).map { ScreenshotTextRegion(id:$0,text:"Entry\($0)",bounds:.zero,lineHeight:0.02) })
    let work = ScreenshotTranslationWork(document:many)
    var active = 0,peak = 0,requests = 0,early = false
    try! await work.run(send:{ input,_,_ in
        active += 1;peak = max(peak,active);requests += 1;defer { active -= 1 }
        try await Task.sleep(nanoseconds:input.contains("Entry0") ? 80_000_000 : 15_000_000)
        return input.replacingOccurrences(of:"Entry",with:"条目")
    },onUpdate:{ _ in },onProgress:{ _,_,_ in },onCommit:{ values in if !values.isEmpty && values.count < many.regions.count { early = true } })
    check(peak == 3 && active == 0,"Screenshot jobs overlap but never exceed three active requests")
    check(requests == 4 && early,"Verified translations become visible before the entire screenshot finishes")
    check(many.regions.allSatisfy { work.completed[$0.id] == "条目\($0.id)" },"Out-of-order network completion retains exact region identities")
    let cancelled = ScreenshotTranslationWork(document:many)
    var cancelledActive = 0
    let task = Task { @MainActor in try await cancelled.run(send:{ input,_,_ in
        cancelledActive += 1;defer { cancelledActive -= 1 };try await Task.sleep(nanoseconds:2_000_000_000);return input
    },onUpdate:{ _ in },onProgress:{ _,_,_ in }) }
    await Task.yield();task.cancel()
    do { try await task.value;fatalError("Cancellation accepted") } catch { check(cancelled.completed.isEmpty && cancelledActive == 0,"Canceling a screenshot stops every sibling request without committing previews") }
    let pair = ScreenshotDocument(regions:[ScreenshotTextRegion(id:0,text:"First label",bounds:.zero,lineHeight:0.02),ScreenshotTextRegion(id:1,text:"Second label",bounds:.zero,lineHeight:0.02)])
    let earlyWork = ScreenshotTranslationWork(document:pair)
    var earlyCommits: [[Int:String]] = []
    try! await earlyWork.run(send:{ input,_,update in
        let regex = try! NSRegularExpression(pattern:"⟦SONUVI_[^⟧]+⟧")
        let markers = regex.matches(in:input,range:NSRange(input.startIndex...,in:input)).map { String(input[Range($0.range,in:input)!]) }
        update(markers[0]+"第一项"+String(markers[1].prefix(5)))
        check(earlyWork.completed.isEmpty,"An unfinished closing marker never makes a preview copyable")
        update(markers[0]+"第一项"+markers[1]+"第")
        check(earlyWork.completed == [0:"第一项"],"A closed first slot is visible while the next slot is still streaming")
        return markers[0]+"第一项"+markers[1]+"第二项"
    },onUpdate:{ _ in },onProgress:{ _,_,_ in },onCommit:{ earlyCommits.append($0) })
    check(earlyCommits.contains([0:"第一项"]) && earlyWork.completed[1] == "第二项","First visible output does not wait for the complete batch")
    let damagedTail = ScreenshotTranslationWork(document:pair);var tailRequests = 0
    try! await damagedTail.run(send:{ input,_,update in
        tailRequests += 1
        if input.contains("⟦SONUVI_") {
            let regex = try! NSRegularExpression(pattern:"⟦SONUVI_[^⟧]+⟧")
            let markers = regex.matches(in:input,range:NSRange(input.startIndex...,in:input)).map { String(input[Range($0.range,in:input)!]) }
            update(markers[0]+"第一项"+markers[1]+"...不完整")
            throw TranslateError.outputLimit
        }
        return "第二项"
    },onUpdate:{ _ in },onProgress:{ _,_,_ in })
    check(tailRequests == 2 && damagedTail.completed == [0:"第一项",1:"第二项"],"A truncated tail retries only unfinished slots, preserving the closed first slot")
    let cache = ScreenshotTranslationCache(capacity:2,lifetime:5)
    cache.store(document:document("Cache Alpha"),values:[0:"甲"],model:"model-one",direction:.toChinese,now:0)
    cache.store(document:document("Cache Beta"),values:[0:"乙"],model:"model-one",direction:.toChinese,now:0)
    check(!cache.values(document:document("Cache Alpha"),model:"model-one",direction:.toChinese,now:1).isEmpty,"A repeated screenshot reuses completed labels across controllers")
    cache.store(document:document("Cache Gamma"),values:[0:"丙"],model:"model-one",direction:.toChinese,now:1)
    check(cache.values(document:document("Cache Beta"),model:"model-one",direction:.toChinese,now:1).isEmpty,"Least-recently-used screenshot text is evicted at the memory limit")
    check(cache.values(document:document("Cache Alpha"),model:"model-two",direction:.toChinese,now:1).isEmpty,"Changing the model cannot reuse a previous model's translation")
    check(cache.values(document:document("Cache Alpha"),model:"model-one",direction:.toChinese,now:7).isEmpty,"Expired screenshot text is not reused indefinitely")
    let model = ScreenshotOverlayModel();model.busy = true;model.document = many;model.completed = [0:"条目0"]
    check(!model.showsOriginal && model.copyText == "条目0","Busy screenshots display and copy verified regions without waiting for all batches")
    model.original = true;check(model.showsOriginal,"Original comparison overrides progressive translation")

    let metadata = ScreenshotDocument(lines:[ScreenshotTextLine(text:"Today",bounds:CGRect(x:0.5,y:0.4,width:0.06,height:0.03),confidence:1),ScreenshotTextLine(text:"2:09",bounds:CGRect(x:0.58,y:0.4,width:0.04,height:0.03),confidence:1)],imageSize:CGSize(width:1000,height:1000))
    check(metadata.text.contains("2:09"),"Real numeric metadata beside a UI label remains copyable")
    check(!ScreenshotTextFilter.detachedAdornment("2:09",body:"Today",icon:CGRect(x:0.5,y:0.4,width:0.04,height:0.03),label:CGRect(x:0.56,y:0.4,width:0.06,height:0.03),imageSize:CGSize(width:1000,height:1000)),"A timestamp is not classified as a decorative prefix")
    check(ScreenshotTextFilter.isDayTimeBoundary(day:"昨天",remainder:"14:30"),"Chinese relative dates and their clock stay in one translation region")
    check(ScreenshotTextFilter.isDayTimeBoundary(day:"Today",remainder:"2:09 PM"),"English relative dates retain their clock and day period")
    check(!ScreenshotTextFilter.isDayTimeBoundary(day:"我",remainder:"14:30"),"Creator and time cells remain separate")
    check(!ScreenshotTextFilter.isDayTimeBoundary(day:"昨天",remainder:"16 KB"),"Relative day labels do not swallow a file-size cell")
    let size = CGSize(width:1900,height:970),fixture = makeScreenshotDarkFixture(),image = fixture.image
    if let png = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) { try! png.write(to:URL(fileURLWithPath:"/tmp/sonuvi-dark-layout-source.png")) }
    let observed = try! await OCRService.recognizeDocument(.image(image),cpuOnly:true)
    let fidelity = CommandLine.arguments.contains("--screenshot-ocr-fidelity-test")
    let required = fidelity ? ["Recent","All Types","Shared","My Devices","Creator","Last Modified","Open"] : ["Recent","All Types","Creator","Open"]
    for label in required { check(observed.regions.contains {$0.text.caseInsensitiveCompare(label) == .orderedSame},"Dark OCR recognizes a source control: "+label) }
    let dark = fidelity ? observed : fixture.document
    check(!dark.regions.contains {$0.text == "Recent C" || $0.text == "All Types Y" || $0.text == "d Shared" || $0.text == "G My Devices"},"Detached refresh, chevron and shared icons do not enter translation text")
    check(!dark.regions.contains { $0.text.contains("Personal Space Me") || $0.text.contains("Personal Space Guest") },"Adjacent location and creator cells remain separate even when Vision combines observations")
    let glyph = CGRect(x:0.1,y:0.6,width:0.02,height:0.03),label = CGRect(x:0.14,y:0.6,width:0.1,height:0.03)
    check(ScreenshotTextFilter.detachedAdornment("d",body:"Shared",icon:glyph,label:label,imageSize:CGSize(width:1000,height:1000)),"An icon misread as a Latin letter is protected next to an English UI label")
    check(!ScreenshotTextFilter.detachedAdornment("A",body:"New scientific method",icon:glyph,label:label,imageSize:CGSize(width:1000,height:1000)),"A sentence's article is preserved for translation")
    var values: [Int:String] = [:]
    for region in dark.regions { if let value = screenshotDarkTranslation(region.text) { values[region.id] = value } }
    let canvas = ScreenshotCanvasView(image:image,size:size)
    let overflow = canvas.update(document:dark,values:values,original:false)
    check(!overflow,"Dark UI labels fit without false overflow")
    let obstacles = ScreenshotLayoutObstacles(image:image,size:size)
    for region in dark.regions where ["Creator","Last Modified","Shared","My Devices","Me","Guest"].contains(region.text) {
        let p = ScreenshotLayout.placement(region:region,text:values[region.id]!,regions:dark.regions,size:size,protectedBounds:dark.protectedBounds,obstacles:obstacles)
        check(p.fontSize >= 11 && p.fontSize <= 16,"Dark UI body and table headers keep their source scale: \(region.text), font=\(p.fontSize), source=\(region.bounds), frame=\(p.frame)")
    }
    let centerCases = dark.regions.filter { $0.bounds.maxX*size.width < 65 && ["Documents","Email","Calendar","Messages","Templates"].contains($0.text) }
    check(centerCases.count >= 3,"The wide fixture includes a centered app-navigation rail")
    for region in centerCases {
        let p = ScreenshotLayout.placement(region:region,text:values[region.id]!,regions:dark.regions,size:size,protectedBounds:dark.protectedBounds,obstacles:obstacles)
        check(p.alignment == .center && abs(p.frame.midX-region.bounds.midX*size.width) < 1.5,"Shorter translated navigation labels retain their original center: "+region.text)
    }
    for region in dark.regions where region.bounds.minX*size.width > 100 && region.bounds.maxX*size.width < 325 && ["Recent","Shared","Label","My Devices"].contains(region.text) {
        let p = ScreenshotLayout.placement(region:region,text:values[region.id]!,regions:dark.regions,size:size,protectedBounds:dark.protectedBounds,obstacles:obstacles)
        check(p.alignment == .left,"Left-aligned sidebar items do not become centered: "+region.text)
    }
    func pixels(_ crop:CGImage) -> [UInt8] {
        var data = [UInt8](repeating:0,count:32*32*4)
        data.withUnsafeMutableBytes { bytes in let c = CGContext(data:bytes.baseAddress,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.interpolationQuality = .none;c.draw(crop,in:CGRect(x:0,y:0,width:32,height:32)) }
        return data
    }
    guard let result = ScreenshotImageRenderer.render(image:image,size:size,document:dark,values:values,original:false) else { fatalError("Dark export overflowed") }
    let before = CapturedDisplay(frame:CGRect(origin:.zero,size:size),image:image),after = CapturedDisplay(frame:CGRect(origin:.zero,size:size),image:result)
    for box in dark.protectedBounds where box.width*size.width > 3 && box.height*size.height > 3 {
        let rect = ScreenshotLayout.rect(box,in:size).insetBy(dx:0.5,dy:0.5)
        if let a = before.crop(rect),let b = after.crop(rect) { check(pixels(a) == pixels(b),"Protected icon pixels survive a dark screenshot translation") }
    }
    if let png = NSBitmapImageRep(cgImage:result).representation(using:.png,properties:[:]) { try! png.write(to:URL(fileURLWithPath:"/tmp/sonuvi-dark-layout-result.png")) }
    return checks
}

private final class ScreenshotTimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String:Double] = [:]
    func set(_ values:[String:Double]) { lock.lock();data = values;lock.unlock() }
    var values:[String:Double] { lock.lock();defer {lock.unlock()};return data }
}
