// Sonuvi — GPL-3.0. Verify weak thumbnail edges against original screenshot pixels.
import AppKit

final class ScreenshotNativeEdgeProbe {
    private struct Band:Hashable {let top:Int;let height:Int}
    private struct Raster {let band:Band;let bytes:[UInt8]}
    private let image:CGImage
    private let scaleX:CGFloat,scaleY:CGFloat
    private var cache:[Band:Raster] = [:]
    private var order:[Band] = []
    private var cachedBytes = 0
    init(image:CGImage,analysisSize:CGSize) {
        self.image = image;scaleX = CGFloat(image.width)/analysisSize.width;scaleY = CGFloat(image.height)/analysisSize.height
    }
    private func raster(source:CGRect) -> Raster? {
        let top = max(0,Int(floor(CGFloat(image.height)-source.maxY*scaleY)))
        let bottom = min(image.height,Int(ceil(CGFloat(image.height)-source.minY*scaleY)))
        guard bottom > top else {return nil}
        let band = Band(top:top,height:bottom-top)
        if let existing = cache[band] {return existing}
        guard let crop = image.cropping(to:CGRect(x:0,y:top,width:image.width,height:band.height)) else {return nil}
        var bytes = [UInt8](repeating:0,count:image.width*band.height*4)
        let rendered = bytes.withUnsafeMutableBytes {buffer -> Bool in
            guard let context = CGContext(data:buffer.baseAddress,width:image.width,height:band.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return false}
            context.interpolationQuality = .none;context.draw(crop,in:CGRect(x:0,y:0,width:image.width,height:band.height));return true
        }
        guard rendered else {return nil}
        let result = Raster(band:band,bytes:bytes)
        // Only thin source rows are decoded. Bound retained memory even for
        // unusually tall OCR blocks or captures spanning several displays.
        if bytes.count <= 8_000_000 {
            while !order.isEmpty && (cachedBytes+bytes.count > 8_000_000 || order.count >= 8) {
                let key = order.removeFirst();cachedBytes -= cache.removeValue(forKey:key)?.bytes.count ?? 0
            }
            cache[band] = result;order.append(band);cachedBytes += bytes.count
        }
        return result
    }
    func edge(near analysisX:Int,source:CGRect,limit:CGFloat,trailing:Bool) -> CGFloat? {
        guard let raster = raster(source:source) else {return nil}
        let lo:Int,hi:Int
        if trailing {
            lo = max(2,Int(ceil(source.maxX*scaleX))+max(2,Int(ceil(scaleX))),Int(floor(CGFloat(analysisX-2)*scaleX)))
            hi = min(image.width-3,Int(floor(limit*scaleX)),Int(ceil(CGFloat(analysisX+2)*scaleX)))
        } else {
            lo = max(2,Int(ceil(limit*scaleX)),Int(floor(CGFloat(analysisX-2)*scaleX)))
            hi = min(image.width-3,Int(floor(source.minX*scaleX))-3,Int(ceil(CGFloat(analysisX+2)*scaleX)))
        }
        guard hi >= lo else {return nil}
        func change(_ x:Int,_ y:Int) -> Int {
            func delta(_ a:Int,_ b:Int) -> Int {
                let left = (y*image.width+a)*4,right = (y*image.width+b)*4
                return max(abs(Int(raster.bytes[left])-Int(raster.bytes[right])),abs(Int(raster.bytes[left+1])-Int(raster.bytes[right+1])),abs(Int(raster.bytes[left+2])-Int(raster.bytes[right+2])))
            }
            return max(delta(x-1,x+1),delta(x-2,x))
        }
        let positions = trailing ? Array(lo...hi) : Array(stride(from:hi,through:lo,by:-1))
        for x in positions {
            var strong = 0,soft = 0
            for y in 0..<raster.band.height {
                let d = change(x,y);if d >= 18 {strong += 1};if d >= 5 {soft += 1}
            }
            if strong >= max(2,Int(ceil(CGFloat(raster.band.height)*0.25))) || soft >= max(3,Int(ceil(CGFloat(raster.band.height)*0.8))) {
                return trailing ? max(source.maxX,CGFloat(x-3)/scaleX) : min(source.minX,CGFloat(x+3)/scaleX)
            }
        }
        return nil
    }
}
