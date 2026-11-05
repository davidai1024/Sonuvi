// Sonuvi — GPL-3.0. Recognize measured text columns without their outline icons.
import AppKit
import Vision

// Vision sometimes gives an icon's box to the first real character even when
// its string omits the icon. Keep candidate ranges intact and map crop-local
// boxes explicitly, rather than guessing which character should be removed.
struct ScreenshotOCRBox {let boundingBox:CGRect}
struct ScreenshotOCRCandidate {
    let value:VNRecognizedText
    let imageRect:CGRect
    var string:String {value.string}
    var confidence:Float {value.confidence}
    func boundingBox(for range:Range<String.Index>) throws -> ScreenshotOCRBox? {
        try value.boundingBox(for:range).map {ScreenshotOCRBox(boundingBox:ScreenshotOCRObservation.map($0.boundingBox,into:imageRect))}
    }
}
struct ScreenshotOCRObservation {
    let value:VNRecognizedTextObservation
    var imageRect = CGRect(x:0,y:0,width:1,height:1)
    var boundingBox:CGRect {Self.map(value.boundingBox,into:imageRect)}
    func topCandidates(_ count:Int) -> [ScreenshotOCRCandidate] {value.topCandidates(count).map {ScreenshotOCRCandidate(value:$0,imageRect:imageRect)}}
    static func map(_ rect:CGRect,into imageRect:CGRect) -> CGRect {
        CGRect(x:imageRect.minX+rect.minX*imageRect.width,y:imageRect.minY+rect.minY*imageRect.height,width:rect.width*imageRect.width,height:rect.height*imageRect.height)
    }
}

enum ScreenshotNavigationRecognition {
    static func refine(_ original:[ScreenshotOCRObservation],image:CGImage,geometry:ScreenshotVisualGeometry,cpuOnly:Bool,cancellation:ScreenshotOCRCancellation) throws -> [ScreenshotOCRObservation] {
        var replacement:[ScreenshotOCRObservation] = []
        let w=CGFloat(image.width),h=CGFloat(image.height)
        for column in geometry.navigationTextColumns {
            try Task.checkCancellation()
            // Crop native pixels without compression or changing the displayed
            // screenshot. The measured gap excludes the original icon pixels.
            let rect=CGRect(x:floor(column.minX*w)-2,y:floor((1-column.maxY)*h)-2,width:ceil(column.maxX*w)-floor(column.minX*w)+4,height:ceil(column.maxY*h)-floor(column.minY*h)+4).intersection(CGRect(x:0,y:0,width:w,height:h))
            guard let crop=image.cropping(to:rect),rect.width > 4,rect.height > 4 else {continue}
            let imageRect=CGRect(x:rect.minX/w,y:1-rect.maxY/h,width:rect.width/w,height:rect.height/h)
            // Very small dark CPU crops can lose a Chinese character despite
            // an intact bitmap. An OCR-only 2x input stabilizes those cases; the
            // normalized box transform still maps to the native source crop.
            let input:CGImage
            let tiny = crop.width < 200 && crop.height < 800
            let cropSize = CGSize(width:crop.width,height:crop.height)
            let background = tiny ? ScreenshotRegionColors.sample(image:crop,rect:CGRect(origin:.zero,size:cropSize),size:cropSize).background.usingColorSpace(.sRGB) : nil
            let dark = background.map {($0.redComponent+$0.greenComponent+$0.blueComponent)/3 < 0.35} ?? false
            if tiny,dark,
               let c=CGContext(data:nil,width:crop.width*2,height:crop.height*2,bitsPerComponent:8,bytesPerRow:0,space:crop.colorSpace?.model == .rgb ? crop.colorSpace! : CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) {
                c.interpolationQuality = .high;c.draw(crop,in:CGRect(x:0,y:0,width:crop.width*2,height:crop.height*2));input=c.makeImage() ?? crop
            } else {input=crop}
            let request=try ScreenshotVisionEngine.perform(image:input,cpuOnly:cpuOnly,cancellation:cancellation)
            for observation in request.results ?? [] {
                let mapped=ScreenshotOCRObservation(value:observation,imageRect:imageRect)
                guard geometry.navigationTextStart(for:mapped.boundingBox) != nil else {continue}
                replacement.append(mapped)
            }
        }
        let replaced=Set(replacement.compactMap {geometry.navigationRowIndex(for:$0.boundingBox)})
        // An unrecognized crop must not silently delete a source label.
        return original.filter {observation in
            guard let row=geometry.navigationRowIndex(for:observation.boundingBox) else {return true}
            return !replaced.contains(row)
        }+replacement
    }
}
