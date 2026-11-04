// Sonuvi — GPL-3.0. Optional read-only semantics; image-only OCR still works.
import AppKit
import ApplicationServices

struct ScreenshotSourceWindow {
    let id:CGWindowID
    let pid:pid_t
    let bounds:CGRect // global Quartz coordinates, top-left
    static func snapshot() -> [ScreenshotSourceWindow] {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,pid != ProcessInfo.processInfo.processIdentifier,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let value = row[kCGWindowBounds as String] as? [String:Any],
                  let bounds = CGRect(dictionaryRepresentation:value as CFDictionary),bounds.width > 20,bounds.height > 20 else {return nil}
            return ScreenshotSourceWindow(id:id,pid:pid,bounds:bounds)
        }
    }
}
struct ScreenshotAccessibilityContext {
    let windows:[ScreenshotSourceWindow]
    let crop:CGRect // global Quartz coordinates
    func read(lines:[ScreenshotTextLine]) -> (controls:[ScreenshotVisualContainer],graphics:[CGRect]) {
        guard AXIsProcessTrusted(),!windows.isEmpty else {return ([],[])}
        let live = Dictionary(uniqueKeysWithValues:ScreenshotSourceWindow.snapshot().map {($0.id,$0.bounds)})
        let stable = windows.filter {live[$0.id] == $0.bounds}
        let deadline = ProcessInfo.processInfo.systemUptime+0.25
        var apps:[pid_t:AXUIElement] = [:],controls:[ScreenshotVisualContainer] = [],graphics:[CGRect] = [],queries = 0
        func valid() -> Bool {!Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline}
        func attribute(_ node:AXUIElement,_ key:String) -> CFTypeRef? {
            guard valid() else {return nil};AXUIElementSetMessagingTimeout(node,0.025)
            var result:CFTypeRef?;return AXUIElementCopyAttributeValue(node,key as CFString,&result) == .success ? result : nil
        }
        func element(_ value:CFTypeRef?) -> AXUIElement? {guard let value,CFGetTypeID(value) == AXUIElementGetTypeID() else{return nil};return (value as! AXUIElement)}
        func box(_ node:AXUIElement) -> CGRect? {
            guard let pv = attribute(node,kAXPositionAttribute),CFGetTypeID(pv) == AXValueGetTypeID(),let sv = attribute(node,kAXSizeAttribute),CFGetTypeID(sv) == AXValueGetTypeID() else{return nil}
            var p = CGPoint.zero,s = CGSize.zero
            guard AXValueGetValue(pv as! AXValue,.cgPoint,&p),AXValueGetValue(sv as! AXValue,.cgSize,&s) else{return nil}
            let r = CGRect(origin:p,size:s)
            guard crop.intersection(r).width*r.intersection(crop).height >= r.width*r.height*0.98,r.width > 2,r.height > 2 else{return nil}
            return CGRect(x:(r.minX-crop.minX)/crop.width,y:1-(r.maxY-crop.minY)/crop.height,width:r.width/crop.width,height:r.height/crop.height)
        }
        let roles:Set<String> = [kAXButtonRole,kAXCheckBoxRole,kAXRadioButtonRole,kAXPopUpButtonRole,kAXComboBoxRole,kAXTextFieldRole,kAXMenuItemRole]
        for line in lines.sorted(by:{$0.bounds.width*$0.bounds.height < $1.bounds.width*$1.bounds.height}) {
            guard valid(),queries < 48 else {break}
            let p = CGPoint(x:crop.minX+line.bounds.midX*crop.width,y:crop.minY+(1-line.bounds.midY)*crop.height)
            guard let window = stable.first(where:{$0.bounds.contains(p)}) else {continue}
            let app = apps[window.pid] ?? AXUIElementCreateApplication(window.pid);apps[window.pid] = app;AXUIElementSetMessagingTimeout(app,0.025)
            var node:AXUIElement?;queries += 1
            guard AXUIElementCopyElementAtPosition(app,Float(p.x),Float(p.y),&node) == .success else {continue}
            for _ in 0..<5 {
                guard let current = node,valid() else {break}
                var pid:pid_t = 0;guard AXUIElementGetPid(current,&pid) == .success,pid == window.pid else {break}
                let role = attribute(current,kAXRoleAttribute) as? String ?? ""
                if attribute(current,kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole {break}
                if role == kAXImageRole,let r = box(current),r.height < line.bounds.height*4,r.width*r.height < 0.02 {graphics.append(r);break}
                if roles.contains(role),let r = box(current),r.height*crop.height < max(100,line.bounds.height*crop.height*4) {
                    controls.append(ScreenshotVisualContainer(bounds:r,compact:true))
                    // Read geometry only: never copy values, titles or field contents.
                    if let children = attribute(current,kAXChildrenAttribute) as? [AXUIElement] {
                        for child in children.prefix(12) where valid() {
                            if attribute(child,kAXRoleAttribute) as? String == kAXImageRole,let image = box(child),image.width*image.height < r.width*r.height*0.6 {graphics.append(image)}
                        }
                    }
                    break
                }
                if role == kAXWindowRole || role == kAXApplicationRole {break}
                node = element(attribute(current,kAXParentAttribute))
            }
        }
        return (controls,graphics)
    }
}
