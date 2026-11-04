// Sonuvi — GPL-3.0. Anonymous wide dark UI: icons, names, avatars and table columns.
import AppKit

@MainActor
func makeScreenshotDarkWorkspaceScene(record: ((String,CGRect,Bool) -> Void)? = nil) -> CGImage {
    let size = CGSize(width:1900,height:970)
    let ctx = CGContext(data:nil,width:3800,height:1940,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x:2,y:2); NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    func fill(_ r: CGRect,_ gray: CGFloat) { NSColor(white:gray,alpha:1).setFill();NSBezierPath(rect:r).fill() }
    func text(_ s: String,_ x: CGFloat,_ y: CGFloat,_ pt: CGFloat = 14,_ color: NSColor = .white) {
        let font = NSFont.systemFont(ofSize:pt),value = NSAttributedString(string:s,attributes:[.font:NSFont.systemFont(ofSize:pt),.foregroundColor:color])
        value.draw(at:CGPoint(x:x,y:y))
        let measured = value.size()
        record?(s,CGRect(x:x,y:y+(measured.height-font.capHeight)/2,width:measured.width,height:font.capHeight),s.count == 1)
    }
    func icon(_ s: String,_ x: CGFloat,_ y: CGFloat,_ pt: CGFloat = 16,_ color: NSColor = .lightGray) {
        guard let img = NSImage(systemSymbolName:s,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:pt,weight:.regular))?.withSymbolConfiguration(.init(paletteColors:[color])) else { return }
        // Draw into the explicit bitmap context; lockFocus creates a display-
        // dependent context and can corrupt later text drawing on headless Macs.
        ctx.saveGState();NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext:ctx,flipped:false)
        img.draw(in:CGRect(x:x,y:y,width:pt+2,height:pt+2))
        record?("",CGRect(x:x,y:y,width:pt+2,height:pt+2),true)
        NSGraphicsContext.restoreGraphicsState();ctx.restoreGState()
    }
    fill(CGRect(origin:.zero,size:size),0.14);fill(CGRect(x:65,y:0,width:260,height:875),0.09)
    let rail = [("Documents","doc.fill"),("Messages","message.fill"),("Email","envelope.fill"),("Calendar","calendar"),("Templates","square.grid.2x2.fill")]
    for (i,item) in rail.enumerated() {
        let y = CGFloat(825-i*105)
        icon(item.1,22,y+23,18,.systemBlue)
        let font = NSFont.systemFont(ofSize:11)
        let width = NSAttributedString(string:item.0,attributes:[.font:font]).size().width
        text(item.0,32-width/2,y,11)
    }
    text("Example Workspace",70,910,18);fill(CGRect(x:600,y:895,width:730,height:38),0.16);text("Search for documents and tips...",635,906,14,.lightGray);icon("magnifyingglass",615,905)
    NSColor.systemBlue.setFill();NSBezierPath(roundedRect:CGRect(x:82,y:820,width:228,height:36),xRadius:5,yRadius:5).fill();icon("plus",168,828,17,.white);text("New",194,831)
    fill(CGRect(x:82,y:772,width:228,height:36),0.16);icon("folder",165,781,16,.systemBlue);text("Open",190,782,14,.systemBlue)
    let labels = [("Recent","clock"),("Starred","star"),("Shared","point.3.connected.trianglepath.dotted"),("Cloud Document",""),("Personal Space","folder"),("Team Space","person.2"),("Wiki","link"),("My Devices","icloud.and.arrow.up"),("Label","tag"),("Recycle Bin","trash"),("Local",""),("Desktop","folder.fill"),("Documents","folder.fill"),("Downloads","folder.fill"),("Browse","ellipsis.circle")]
    for (i,item) in labels.enumerated() {
        let y = CGFloat(720-i*40);text(item.0,130,y)
        if !item.1.isEmpty { icon(item.1,106,y-1) }
        if [4,5,7,8].contains(i) { icon("chevron.right",92,y+3,9) }
    }
    text("Recent",365,824,22);icon("arrow.clockwise",442,824,19)
    text("All Types",365,775);icon("chevron.down",435,777,11)
    text("All Locations",1280,775);icon("chevron.down",1375,777,11)
    text("Creator",1400,775);icon("chevron.down",1456,777,11);text("Last Modified",1525,775)
    fill(CGRect(x:365,y:763,width:1500,height:1),0.22);text("Today",365,728)
    let filenames = ["Quarterly Planning.xlsx","Product Overview.pptx","Research Notes.docx","Prototype Review.xlsx","Design Library","Release Checklist.docx","Team Progress","User Research.xlsx"]
    for (i,name) in filenames.enumerated() {
        let y = CGFloat(680-i*69)
        let color: NSColor = i == 1 ? .systemOrange : i == 2 || i == 5 ? .systemBlue : .systemGreen
        color.setFill();NSBezierPath(roundedRect:CGRect(x:365,y:y-2,width:24,height:25),xRadius:3,yRadius:3).fill();text(i == 1 ? "P" : i == 2 || i == 5 ? "W" : "S",370,y+2)
        text(name,402,y+2)
        for avatar in 0..<(i%4+1) { NSColor(white:CGFloat(avatar)*0.05+0.28,alpha:1).setFill();NSBezierPath(ovalIn:CGRect(x:1160+CGFloat(avatar)*13,y:y-1,width:22,height:22)).fill();text("•",1166+CGFloat(avatar)*13,y+2,10,.lightGray) }
        text(i%3 == 0 ? "My Devices" : "Personal Space",1280,y+2,14,.gray);text(i%2 == 0 ? "Me" : "Guest",1400,y+2,14,.gray);text(i%2 == 0 ? "Today 2:09 PM" : "Yesterday 3:49 PM",1525,y+2,14,.gray)
        fill(CGRect(x:400,y:y-19,width:1450,height:1),0.22)
    }
    text("Synthetic dark screenshot fixture · anonymous content",365,45,12,.gray)
    return ctx.makeImage()!
}

// Known drawing coordinates test layout independently of OS-specific OCR spelling.
@MainActor
func makeScreenshotDarkFixture() -> (image:CGImage,document:ScreenshotDocument) {
    var labels: [(String,CGRect)] = [],icons: [CGRect] = []
    let image = makeScreenshotDarkWorkspaceScene { text,box,icon in
        let normalized = CGRect(x:box.minX/1900,y:box.minY/970,width:box.width/1900,height:box.height/970)
        if icon { icons.append(normalized) } else { labels.append((text,normalized)) }
    }
    labels.sort { abs($0.1.midY-$1.1.midY) > 0.008 ? $0.1.midY > $1.1.midY : $0.1.minX < $1.1.minX }
    let regions = labels.enumerated().map { ScreenshotTextRegion(id:$0.offset,text:$0.element.0,bounds:$0.element.1,lineHeight:$0.element.1.height) }
    return (image,ScreenshotDocument(regions:regions,protectedBounds:icons))
}
