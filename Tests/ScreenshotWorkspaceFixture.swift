// Sonuvi — GPL-3.0. Synthetic acceptance scenes, rendered by the production workspace.
import AppKit

private var screenshotWorkspaceFixture: ScreenshotTranslationController?
private var screenshotSourceWindow: NSWindow?

@MainActor
func runScreenshotSourceFixture() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let image = makeScreenshotWorkspaceScene(diagram: false)
    let window = NSWindow(contentRect: CGRect(x: 240, y: 180, width: 1040, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Synthetic Screenshot Source · No User Data"; window.isReleasedWhenClosed = false
    let view = NSImageView(frame: CGRect(x: 0, y: 0, width: 1040, height: 650)); view.image = NSImage(cgImage: image, size: NSSize(width: 1040, height: 650))
    view.imageScaling = .scaleAxesIndependently; window.contentView = view; screenshotSourceWindow = window
    let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
    submenu.addItem(withTitle: "Quit Test Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
}

@MainActor
func makeScreenshotWorkspaceScene(diagram: Bool) -> CGImage {
    let width = 1040, height = 650, scale = 2
    let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    func box(_ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 13, bold: Bool = false, color: NSColor = .black) {
        NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color]).draw(at: CGPoint(x: x, y: y))
    }
    box(CGRect(x: 0, y: 0, width: width, height: height), .white)
    if diagram {
        text("JOURNAL OF VISUAL SYSTEMS", 718, 618, 11)
        text("4", 30, 618, 12)
        // Non-text content must survive translation: a grid, diagram connectors,
        // colored model blocks, and math labels deliberately share the image.
        for column in 0..<3 {
            let x = CGFloat(55 + column * 360)
            box(CGRect(x: x, y: 350, width: 190, height: 130), NSColor(srgbRed: 0.18, green: 0.22, blue: 0.26, alpha: 1))
            for row in 0..<5 { box(CGRect(x: x+5, y: 355+CGFloat(row)*25, width: 180, height: 1), .lightGray) }
            for col in 0..<7 { box(CGRect(x: x+5+CGFloat(col)*26, y: 355, width: 1, height: 120), .gray) }
            box(CGRect(x: x+60, y: 392, width: 60, height: 25), .systemYellow)
        }
        box(CGRect(x: 270, y: 390, width: 120, height: 2), .black)
        box(CGRect(x: 630, y: 390, width: 120, height: 2), .black)
        text("Input image", 100, 315, 15, bold: true)
        text("Prediction grid", 460, 315, 15, bold: true)
        text("Final output", 835, 315, 15, bold: true)
        box(CGRect(x: 305, y: 210, width: 150, height: 60), NSColor(white: 0.8, alpha: 1))
        text("CNN model", 335, 231, 15)
        box(CGRect(x: 500, y: 210, width: 150, height: 60), NSColor(srgbRed: 0.95, green: 0.35, blue: 0.30, alpha: 1))
        text("Loss function", 520, 231, 15)
        text("Update", 344, 285, 14)
        text("F(I, Ω)", 320, 420, 24)
        text("x = 0.5", 695, 232, 19)
        text("Figure 2. Each grid cell predicts two bounding boxes. Low-confidence predictions are discarded.", 35, 110, 16)
        text("The final output retains the most confident region while preserving the original image structure.", 35, 82, 16)
        text("Illustrative test diagram · synthetic content", 35, 30, 11, color: .gray)
    } else {
        box(CGRect(x: 0, y: 0, width: 194, height: height), NSColor(white: 0.95, alpha: 1))
        box(CGRect(x: 0, y: 590, width: width, height: 60), NSColor(white: 0.92, alpha: 1))
        text("示例文档", 20, 612, 16, bold: true)
        box(CGRect(x: 270, y: 603, width: 500, height: 30), .white, radius: 7)
        text("搜索文件、模板、应用", 290, 611, 13, color: .darkGray)
        box(CGRect(x: 18, y: 528, width: 158, height: 38), .systemBlue, radius: 5)
        text("新建", 83, 540, 14, color: .white)
        box(CGRect(x: 18, y: 480, width: 158, height: 35), .white, radius: 5)
        text("打开", 83, 491, 14)
        for (index, title) in ["最近", "星标", "共享", "云文档", "我的设备", "标签", "回收站", "本地", "桌面", "文稿", "下载", "工作台"].enumerated() {
            let y = CGFloat(437-index*34)
            let symbols = ["clock", "star", "person.2", "cloud", "desktopcomputer", "tag", "trash", "internaldrive", "folder", "doc", "arrow.down.circle", "square.grid.2x2"]
            if let symbol = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                symbol.draw(in: CGRect(x: 27, y: y+1, width: 17, height: 17))
            }
            text(title, 52, y, 12)
        }
        box(CGRect(x: 193, y: 0, width: 1, height: 590), NSColor(white: 0.8, alpha: 1))
        text("快速访问", 224, 542, 22, bold: true)
        text("最近", 224, 494, 21, bold: true)
        text("全部类型", 224, 451, 12, bold: true)
        text("文件位置", 650, 451, 12, bold: true)
        text("创建者", 765, 451, 12, bold: true)
        text("最近修改", 855, 451, 12, bold: true)
        text("大小", 975, 451, 12, bold: true)
        box(CGRect(x: 215, y: 440, width: 810, height: 1), NSColor(white: 0.88, alpha: 1))
        text("今天", 224, 413, 15, bold: true)
        let titles = ["A New CNN-Based Method.pdf", "DeepSeek R1.pdf", "研究资料与实验记录.docx", "中国经济发展观察报告.pdf", "改革与创新.pdf", "移动组件阅读模式调研.xlsx"]
        for (index, title) in titles.enumerated() {
            let y = CGFloat(374-index*53)
            box(CGRect(x: 224, y: y-2, width: 20, height: 24), index == 2 ? .systemBlue : index == 5 ? .systemGreen : .systemRed, radius: 3)
            text(index == 2 ? "W" : index == 5 ? "X" : "P", 229, y+2, 12, bold: true, color: .white)
            text(title, 255, y+2, 12)
            text(index == 4 ? "我的云文档" : "我的设备", 650, y+2, 12)
            text("我", 778, y+2, 12)
            text(index == 2 ? "昨天 14:30" : "今天 11:18", 855, y+2, 12)
            text(["2.7 MB", "5.3 MB", "16 KB", "7.8 MB", "1.1 MB", "11 KB"][index], 972, y+2, 12)
            box(CGRect(x: 215, y: y-17, width: 810, height: 1), NSColor(white: 0.93, alpha: 1))
        }
        text("仅用于排版验收的合成测试画面", 224, 25, 11, color: .gray)
    }
    return context.makeImage()!
}

@MainActor
func runScreenshotWorkspaceFixture() {
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    AppLocalization.shared.language = .chinese
    let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
    submenu.addItem(withTitle: "Quit Test Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
    guard let screen = NSScreen.screens.first else { return }
    let diagram = Bundle.main.object(forInfoDictionaryKey: "ScreenshotWorkspaceScene") as? String == "diagram"
    let dark = Bundle.main.object(forInfoDictionaryKey: "ScreenshotWorkspaceScene") as? String == "dark"
    let navigation = Bundle.main.object(forInfoDictionaryKey: "ScreenshotWorkspaceScene") as? String == "navigation"
    let image = navigation ? makeScreenshotNavigationScene() : dark ? makeScreenshotDarkWorkspaceScene() : makeScreenshotWorkspaceScene(diagram: diagram)
    let logical = navigation ? CGSize(width:263,height:725) : dark ? CGSize(width:1900,height:970) : CGSize(width:1040,height:650)
    let fit = min(1,min((screen.frame.width-60)/logical.width,(screen.frame.height-100)/logical.height))
    let size = CGSize(width:logical.width*fit,height:logical.height*fit)
    let rect = CGRect(x: screen.frame.midX-size.width/2, y: screen.frame.midY-size.height/2, width: size.width, height: size.height)
    let context = CGContext(data: nil, width: Int(screen.frame.width*2), height: Int(screen.frame.height*2), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor(white: 0.91, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: screen.frame.width*2, height: screen.frame.height*2))
    context.draw(image, in: CGRect(x: (rect.minX-screen.frame.minX)*2, y: (rect.minY-screen.frame.minY)*2, width: rect.width*2, height: rect.height*2))
    var displays = [CapturedDisplay(frame: screen.frame, image: context.makeImage()!)]
    for other in NSScreen.screens where other !== screen {
        displays.append(CapturedDisplay(frame: other.frame, image: makeSolidScreenshot(width: Int(other.frame.width*2), height: Int(other.frame.height*2), gray: 0.91)))
    }
    let snapshot = FrozenCapture(displays: displays)
    let cropped = snapshot.crop(rect)!
    let controller = ScreenshotTranslationController(image: cropped, selection: rect, modelName: "fixture", snapshot: snapshot)
    controller.model.targetLanguage = diagram || dark || navigation ? .chinese : .english
    controller.recognizeOverride = { try await OCRService.recognizeDocument(.image($0), cpuOnly: true) }
    let pairs = [
        "搜索文件、模板、应用": "Search files, templates, apps", "示例文档": "Sample Documents", "快速访问": "Quick Access", "最近修改": "Modified",
        "新建": "New", "打开": "Open", "最近": "Recent", "星标": "Starred", "共享": "Shared", "云文档": "Cloud Documents", "我的设备": "My Devices", "我的云文档": "My Cloud Documents",
        "标签": "Tags", "回收站": "Recycle Bin", "本地": "Local", "桌面": "Desktop", "文稿": "Documents", "下载": "Downloads", "工作台": "Workbench",
        "全部类型": "All Types", "文件位置": "Location", "创建者": "Creator", "大小": "Size", "今天": "Today ", "昨天": "Yesterday ", "我": "Me",
        "研究资料与实验记录.docx": "Research Notes and Experiments.docx", "中国经济发展观察报告.pdf": "Economic Development Report.pdf", "改革与创新.pdf": "Reform and Innovation.pdf", "移动组件阅读模式调研": "Mobile Reading Study",
        "仅用于排版验收的合成测试画面": "Synthetic layout acceptance scene",
        "JOURNAL OF VISUAL SYSTEMS": "视觉系统期刊", "Input image": "输入图像", "Prediction grid": "预测网格", "Final output": "最终输出", "CNN model": "卷积神经网络", "Loss function": "损失函数", "Update": "更新",
        "Figure 2. Each grid cell predicts two bounding boxes. Low-confidence predictions are discarded.": "图2. 每个网格单元预测两个边界框，低置信度的预测结果会被丢弃。",
        "The final output retains the most confident region while preserving the original image structure.": "最终输出保留置信度最高的区域，同时保持原始图像结构。",
        "Illustrative test diagram": "合成图示", "synthetic content": "测试内容"
    ]
    controller.sendOverride = { input, _, update in
        let slow = Bundle.main.object(forInfoDictionaryKey:"ScreenshotWorkspaceSlowFixture") as? Bool == true
        let delay: UInt64 = slow ? (input.contains("Recent") ? 200_000_000 : 12_000_000_000) : 180_000_000
        try await Task.sleep(nanoseconds:delay)
        var output = input
        if dark || navigation {
            let map = navigation ? ScreenshotNavigationTranslations : ScreenshotDarkTranslations
            for key in map.keys.sorted(by: { $0.count > $1.count }) { output = output.replacingOccurrences(of:key,with:map[key]!,options:.caseInsensitive) }
            update(output); return output
        }
        for key in pairs.keys.sorted(by: { $0.count > $1.count }) { output = output.replacingOccurrences(of: key, with: pairs[key]!) }
        // Account for local Vision substitutions in this generated font fixture;
        // production requests use the actual provider, not this replacement map.
        output = output.replacingOccurrences(of: #"Figure 2\.[^\n⟦]+"#, with: "图2. 每个网格单元预测两个边界框，低置信度的预测结果会被丢弃。", options: .regularExpression)
            .replacingOccurrences(of: #"The final output[^\n⟦]+"#, with: "最终输出保留置信度最高的区域，同时保持原始图像结构。", options: .regularExpression)
            .replacingOccurrences(of: #"移动组件[^\n⟦]+"#, with: "Mobile Reading Study.xlsx", options: .regularExpression)
            .replacingOccurrences(of: "Upaate", with: "更新").replacingOccurrences(of: "Hlustrative test diagram", with: "合成图示")
        update(output); return output
    }
    controller.onClose = { app.terminate(nil) }; screenshotWorkspaceFixture = controller
    controller.show(); app.activate(ignoringOtherApps: true)
}

@MainActor
func runScreenshotProviderTest() async {
    do {
        let image = makeScreenshotWorkspaceScene(diagram: false)
        let document = try await OCRService.recognizeDocument(.image(image), cpuOnly: true)
        let model = ScreenshotOverlayModel(); model.document = document
        let direction = model.resolvedTarget.direction!
        let work = ScreenshotTranslationWork(document: document, direction: direction)
        let key = try KeyStore.read(allowInteraction: true)
        let name = UserDefaults.standard.string(forKey: "modelName") ?? "deepseek-flash"
        let start = Date(); var requests = 0
        try await work.run(send: { text, direction, update in
            requests += 1
            return try await DeepSeekClient.stream(DeepSeekClient.screenshotRequest(text: text, direction: direction, model: name, key: key), onDelta: update)
        }, onUpdate: { _ in }, onProgress: { _,_,_ in })
        guard work.completed.count == document.regions.count else { throw TranslateError.message("Live screenshot test returned incomplete regions") }
        let titles = document.regions.filter { $0.text.contains("DeepSeek") || $0.text.contains("CNN-Based") }
        guard !titles.isEmpty, titles.allSatisfy({ work.completed[$0.id] == $0.text }) else { throw TranslateError.message("Existing English filenames changed") }
        let translated = work.completed.values.joined(separator: "\n").lowercased()
        guard translated.contains("quick access"), translated.contains("new"), translated.contains("open") else { throw TranslateError.message("Expected translated UI labels missing") }
        guard let rendered = ScreenshotImageRenderer.render(image: image, size: CGSize(width: 1040, height: 650), document: document, values: work.completed, original: false),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { throw TranslateError.message("Live screenshot layout overflowed") }
        try png.write(to: URL(fileURLWithPath: "/tmp/sonuvi-live-screenshot-test.png"))
        print("PASS: live DeepSeek screenshot translation, \(document.regions.count) regions, \(requests) requests, \(String(format: "%.2f", Date().timeIntervalSince(start))) s; English filenames preserved; 2080x1300 PNG rendered")
        exit(0)
    } catch { fputs("Live screenshot test failed: \(error.localizedDescription)\n", stderr); exit(1) }
}
