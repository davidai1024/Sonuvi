// Sonuvi — GPL-3.0. Border pixels must survive high-DPI analysis scaling.
import AppKit

@MainActor
func runScreenshotThinBoundaryChecks() -> Int {
    var checks = 0
    func check(_ pass:Bool,_ message:String) {guard pass else {fatalError("FAIL: "+message)};checks += 1}
    let source = ScreenshotTextRegion(id:0,text:"设置",bounds:CGRect(x:40.0/640,y:100.0/360,width:24.0/640,height:16.0/360),lineHeight:16.0/360)
    for pixels in [640,1280,2560,3840] {
        for contrast in [8,12,16,24,80] {
            for thickness in [1,2] {
                for vertical in [true,false] {
                    autoreleasepool {
                        let scale = CGFloat(pixels)/640,height = Int(360*scale)
                        let c = CGContext(data:nil,width:pixels,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                        c.setFillColor(CGColor(gray:32.0/255,alpha:1));c.fill(CGRect(x:0,y:0,width:pixels,height:height))
                        c.setFillColor(CGColor(gray:CGFloat(32+contrast)/255,alpha:1))
                        c.fill(vertical ? CGRect(x:300*scale,y:90*scale,width:CGFloat(thickness),height:40*scale) : CGRect(x:0,y:60*scale,width:CGFloat(pixels),height:CGFloat(thickness)))
                        let geometry = ScreenshotVisualGeometry(image:c.makeImage()!),r = geometry.constrain(ScreenshotDocument(regions:[source])).regions[0]
                        let boundary = vertical ? r.viewport!.maxX*640 : r.viewport!.minY*360
                        check(vertical ? (292...300).contains(boundary) : (60...68).contains(boundary),"Thin border remains a hard boundary: width=\(pixels), contrast=\(contrast), thickness=\(thickness), vertical=\(vertical), observed=\(boundary)")
                    }
                }
            }
        }
    }
    // Low-resolution color changes alone are not evidence of a border.
    for pixels in [2560,3840] {
        for delta in [80,128] {
            for span in [30,50] {
                autoreleasepool {
                    let scale = CGFloat(pixels)/640,height = Int(360*scale)
                    let c = CGContext(data:nil,width:pixels,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    for x in 0..<pixels {
                        let fraction = max(0,min(1,(CGFloat(x)/scale-200)/CGFloat(span)))
                        c.setFillColor(CGColor(gray:(32+CGFloat(delta)*fraction)/255,alpha:1));c.fill(CGRect(x:x,y:0,width:1,height:height))
                    }
                    let r = ScreenshotVisualGeometry(image:c.makeImage()!).constrain(ScreenshotDocument(regions:[source])).regions[0]
                    check(r.viewport!.maxX*640 > 630,"A smooth gradient is rejected by original-pixel edge verification")
                }
            }
        }
    }
    return checks
}
