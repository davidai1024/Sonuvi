// Sonuvi — GPL-3.0. Local image geometry, independent of OCR vocabulary.
import AppKit

struct ScreenshotVisualContainer {
    let bounds: CGRect // normalized, bottom-left
    let compact: Bool
    var segment = false
}

final class ScreenshotVisualGeometry {
    private struct Component {
        var x0:Int;var y0:Int;var x1:Int;var y1:Int;var area:Int;let key:UInt32
        var rect:CGRect { CGRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1) }
    }
    private let width:Int,height:Int
    private let pixels:[UInt8]
    private let nativeEdges:ScreenshotNativeEdgeProbe?
    private var components:[Component] = []
    private(set) var containers:[ScreenshotVisualContainer] = []
    private var squareColors:[CGRect] = []
    private var navigationRows:[(icon:CGRect,label:CGRect)] = []
    init(image:CGImage) {
        let scale = min(1,1280 / CGFloat(max(image.width,image.height)))
        width = max(1,Int(CGFloat(image.width)*scale));height = max(1,Int(CGFloat(image.height)*scale))
        nativeEdges = image.width > width || image.height > height ? ScreenshotNativeEdgeProbe(image:image,analysisSize:CGSize(width:width,height:height)) : nil
        let w = width,h = height
        var data = [UInt8](repeating:0,count:w*h*4)
        data.withUnsafeMutableBytes { b in
            let c = CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.interpolationQuality = .medium;c.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        pixels = data
        detect()
    }
    private func color(_ x:Int,_ y:Int) -> (Int,Int,Int) {
        let i = (max(0,min(height-1,y))*width+max(0,min(width-1,x)))*4
        return (Int(pixels[i]),Int(pixels[i+1]),Int(pixels[i+2]))
    }
    private func distance(_ a:(Int,Int,Int),_ b:(Int,Int,Int)) -> Int { max(abs(a.0-b.0),abs(a.1-b.1),abs(a.2-b.2)) }
    private func normalized(_ r:CGRect) -> CGRect { CGRect(x:r.minX/CGFloat(width),y:1-r.maxY/CGFloat(height),width:r.width/CGFloat(width),height:r.height/CGFloat(height)) }
    private func pixelRect(_ r:CGRect) -> CGRect { CGRect(x:r.minX*CGFloat(width),y:(1-r.maxY)*CGFloat(height),width:r.width*CGFloat(width),height:r.height*CGFloat(height)) }
    private func detect() {
        var labels = [Int32](repeating:0,count:width*height),keys = [UInt32](repeating:0,count:width*height),parents:[Int32] = [0]
        func root(_ n:Int32) -> Int32 { var x = n;while parents[Int(x)] != x {parents[Int(x)] = parents[Int(parents[Int(x)])];x = parents[Int(x)]};return x }
        for y in 0..<height { for x in 0..<width {
            let i = y*width+x,j = i*4,k = UInt32(pixels[j]>>2)<<12 | UInt32(pixels[j+1]>>2)<<6 | UInt32(pixels[j+2]>>2);keys[i] = k
            let left:Int32 = x > 0 && keys[i-1] == k ? labels[i-1] : 0
            let top:Int32 = y > 0 && keys[i-width] == k ? labels[i-width] : 0
            if left != 0 { labels[i] = left;if top != 0 {let a = root(left),b = root(top);if a != b {parents[Int(b)] = a}} }
            else if top != 0 {labels[i] = top}
            else {labels[i] = Int32(parents.count);parents.append(labels[i])}
        } }
        var byRoot:[Int32:Int] = [:]
        for y in 0..<height { for x in 0..<width {
            let i = y*width+x,r = root(labels[i])
            if let n = byRoot[r] {components[n].x0 = min(components[n].x0,x);components[n].x1 = max(components[n].x1,x);components[n].y0 = min(components[n].y0,y);components[n].y1 = max(components[n].y1,y);components[n].area += 1}
            else {byRoot[r] = components.count;components.append(Component(x0:x,y0:y,x1:x,y1:y,area:1,key:keys[i]))}
        } }
        for c in components {
            let r = c.rect,fill = CGFloat(c.area)/(r.width*r.height)
            guard c.area >= 30,r.height >= 9,fill >= 0.3 else {continue}
            let rgb = (Int((c.key>>12)&63)*4+2,Int((c.key>>6)&63)*4+2,Int(c.key&63)*4+2)
            if r.width/r.height > 0.65,r.width/r.height < 1.5,r.height < 65, max(rgb.0,rgb.1,rgb.2)-min(rgb.0,rgb.1,rgb.2) > 18,edgeStrength(r) >= 0.5 {squareColors.append(normalized(r))}
            guard !(r.width > CGFloat(width)*0.98 && r.height > CGFloat(height)*0.98),fill >= 0.62,r.width >= max(18,r.height*1.3),r.height >= 13,edgeStrength(r) >= 0.7 else {continue}
            containers.append(ScreenshotVisualContainer(bounds:normalized(r),compact:r.height < min(100,CGFloat(height)*0.13)))
        }
        // A selected chip identifies the equal cells of its enclosing segmented control.
        var cells:[ScreenshotVisualContainer] = []
        for parent in containers where parent.compact {
            let p = pixelRect(parent.bounds)
            for child in containers where child.compact {
                let c = pixelRect(child.bounds)
                guard p.insetBy(dx:1,dy:1).contains(c),c.height/p.height > 0.55,c.height/p.height < 0.93,abs(c.midY-p.midY) < p.height*0.12 else {continue}
                let count = Int((p.width/c.width).rounded())
                guard (2...6).contains(count),abs(p.width/c.width-CGFloat(count)) < 0.35 else {continue}
                let pad = max(2,(p.height-c.height)/2),inner = p.insetBy(dx:pad,dy:pad)
                let cellWidth = inner.width/CGFloat(count)
                let expected = inner.minX+(floor((c.midX-inner.minX)/cellWidth)+0.5)*cellWidth
                guard abs(expected-c.midX) < p.height*0.2 else {continue}
                for i in 0..<count {cells.append(ScreenshotVisualContainer(bounds:normalized(CGRect(x:inner.minX+CGFloat(i)*cellWidth,y:inner.minY,width:cellWidth,height:inner.height)),compact:true,segment:true))}
                break
            }
        }
        containers += cells
    }
    private func edgeStrength(_ r:CGRect) -> CGFloat {
        var sides = 0
        for side in 0..<4 {
            let vertical = side < 2,edge = vertical ? (side == 0 ? r.minX : r.maxX-1) : (side == 2 ? r.minY : r.maxY-1)
            let touches = vertical ? (edge < 2 || edge > CGFloat(width-3)) : (edge < 2 || edge > CGFloat(height-3))
            if touches {sides += 1;continue}
            var strong = 0
            for i in 1...9 {
                let t = CGFloat(i)/10,pos = vertical ? r.minY+r.height*t : r.minX+r.width*t
                let sign = side == 0 || side == 2 ? 1 : -1
                let a = vertical ? color(Int(edge)+sign*2,Int(pos)) : color(Int(pos),Int(edge)+sign*2)
                let b = vertical ? color(Int(edge)-sign*3,Int(pos)) : color(Int(pos),Int(edge)-sign*3)
                if distance(a,b) >= 4 {strong += 1}
            }
            if strong >= 5 {sides += 1}
        }
        return CGFloat(sides)/4
    }
    func container(for bounds:CGRect) -> ScreenshotVisualContainer? {
        let box = pixelRect(bounds)
        return containers.filter { c in
            let r = pixelRect(c.bounds),intersection = r.intersection(box)
            return r.insetBy(dx:-2,dy:-2).contains(CGPoint(x:box.midX,y:box.midY)) && !intersection.isNull && intersection.width*intersection.height >= box.width*box.height*0.8
        }.min { a,b in
            if a.segment != b.segment {return a.segment}
            return a.bounds.width*a.bounds.height < b.bounds.width*b.bounds.height
        }
    }
    func graphics(for lines:[ScreenshotTextLine]) -> [CGRect] {
        let heights = lines.map {$0.bounds.height*CGFloat(height)}.sorted(),median = heights.isEmpty ? 12 : heights[heights.count/2]
        var masks = navigationGraphics(for:lines) + squareColors.filter { tile in
            lines.contains { line in
                let overlap = tile.intersection(line.bounds)
                return !overlap.isNull && overlap.width*overlap.height >= line.bounds.width*line.bounds.height*0.8 && tile.height > line.bounds.height*1.15
            }
        }
        // Repeated compact graphic columns (navigation rails) are structural,
        // regardless of which alphabet Vision hallucinates inside their tiles.
        for line in lines where line.text.count <= 3 {
            let r = pixelRect(line.bounds)
            guard r.width/r.height > 0.35,r.width/r.height < 1.9 else {continue}
            let peers = lines.filter { other in
                let s = pixelRect(other.bounds)
                return other.text.count <= 3 && abs(s.midX-r.midX) < median*0.55 && abs(s.midY-r.midY) > median*1.5 && s.height/r.height > 0.65 && s.height/r.height < 1.5
                    && lines.contains { label in let b = pixelRect(label.bounds);return b.minX > s.maxX && b.minX-s.maxX < median*2 && abs(b.midY-s.midY) < median*0.5 && label.text.count >= 2 }
            }
            if peers.count >= 3,tileBehind(r),lines.contains(where: {label in let b = pixelRect(label.bounds);return b.minX > r.maxX && b.minX-r.maxX < median*2 && abs(b.midY-r.midY) < median*0.5 && label.text.count >= 2}) {masks.append(normalized(r.insetBy(dx:-1,dy:-1)))}
            // A symbol paired with another small outline in an isolated action
            // cluster has no prose label. Preserve both original graphics.
            let pairedSymbol = lines.contains {other in
                let s = pixelRect(other.bounds),gap = max(s.minX-r.maxX,r.minX-s.maxX)
                return other.text != line.text && other.text.unicodeScalars.allSatisfy {!CharacterSet.alphanumerics.contains($0)} && gap > median*0.5 && gap < median*4 && abs(s.midY-r.midY) < median*0.4 && s.height/r.height > 0.7 && s.height/r.height < 1.4
            }
            if pairedSymbol,r.width/r.height > 0.65,r.width/r.height < 1.4 {masks.append(normalized(r.insetBy(dx:-1,dy:-1)))}
        }
        // A detached glyph vertically centered beside a two-line description
        // belongs to that row's graphic slot, rather than either text baseline.
        for line in lines where line.text.count <= 2 {
            let r = pixelRect(line.bounds)
            let labels = lines.filter { other in let b = pixelRect(other.bounds);return other.text.count >= 3 && b.minX > r.maxX && b.minX-r.maxX < median*2 && abs(b.midY-r.midY) < median*1.4 }
            if labels.contains(where: {a in labels.contains {b in let p = pixelRect(a.bounds),q = pixelRect(b.bounds);return p.midY < r.midY && q.midY > r.midY && abs(p.minX-q.minX) < median*0.5 && abs((p.midY+q.midY)/2-r.midY) < median*0.3 && r.width < median*1.8}}) {masks.append(normalized(r.insetBy(dx:-1,dy:-1)))}
        }
        // Preserve a large compact emblem beside a smaller brand name; its OCR
        // confidence does not turn a logo into translatable prose.
        for line in lines {
            let r = pixelRect(line.bounds),ratio = r.width/max(1,r.height)
            if line.text.count <= 2,r.minX < CGFloat(width)*0.2,r.minY < CGFloat(height)*0.2,r.height > median*1.65,ratio > 0.55,ratio < 1.35,
               lines.contains(where: { other in let s = pixelRect(other.bounds);return s.minX > r.maxX && s.minX-r.maxX < r.height*2.5 && abs(s.midY-r.midY) < r.height && s.height < r.height*0.8 && other.text.count >= 2 }) {masks.append(line.bounds)}
        }
        for control in containers where control.compact && !control.segment {
            let r = pixelRect(control.bounds)
            guard r.width > r.height*1.7 else {continue}
            let groups = inkGroups(in:r)
            guard groups.count >= 2 else {continue}
            for trailing in [false,true] {
                let g = trailing ? groups.last! : groups.first!,others = trailing ? Array(groups.dropLast()) : Array(groups.dropFirst())
                let body = others.reduce(CGRect.null) {$0.union($1)},gap = trailing ? g.minX-body.maxX : body.minX-g.maxX
                let isSymbolEdge = trailing && g.width < g.height*0.8
                let candidate = lines.first {pixelRect($0.bounds).intersection(g).width*g.height >= g.width*g.height*0.6}
                let isOrdinaryWord = candidate.map { $0.text.count > 1 && $0.text.allSatisfy {$0.isASCII && $0.isLetter} } ?? false
                let density = inkDensity(g,background:backgroundColor(r))
                if !isOrdinaryWord,g.width <= r.height*1.4,g.height >= r.height*0.25,gap >= max(2,r.height*0.12),body.width > g.width*1.6,
                   (isSymbolEdge || g.height > body.height*1.12 || density < 0.36 && g.width/g.height < 1.6) {masks.append(normalized(g.insetBy(dx:-1,dy:-1)))}
            }
        }
        return masks
    }
    func constrain(_ document:ScreenshotDocument, semantic:[ScreenshotVisualContainer] = []) -> ScreenshotDocument {
        func logical(_ r:CGRect) -> CGRect {CGRect(x:r.minX*CGFloat(width),y:r.minY*CGFloat(height),width:r.width*CGFloat(width),height:r.height*CGFloat(height))}
        let canvas = CGRect(x:2,y:2,width:max(1,width-4),height:max(1,height-4))
        let navigation = document.regions.compactMap {region -> (region:ScreenshotTextRegion,x:CGFloat)? in
            navigationTextStart(for:region.bounds).map {(region,$0)}
        }
        let regions = document.regions.map { original -> ScreenshotTextRegion in
            var region = original
            // Descenders, selected bold labels and misrecognized outlines must
            // not assign a different font size to every row of one navigation.
            if let start = navigationTextStart(for:region.bounds) {
                let heights = navigation.filter {abs($0.x-start)*CGFloat(width) < max(2,region.lineHeight*CGFloat(height)*0.6)}.map {$0.region.lineHeight}.sorted()
                if heights.count >= 4 {region.fontLineHeight = heights[heights.count/2]}
            }
            let source = logical(region.bounds),line = region.lineHeight*CGFloat(height)
            let axCandidate = semantic.filter {$0.bounds.contains(CGPoint(x:region.bounds.midX,y:region.bounds.midY))}.min {$0.bounds.width*$0.bounds.height < $1.bounds.width*$1.bounds.height}
            // Some apps expose only the label's accessibility hit frame. That
            // is not evidence of a visible button edge and must not reintroduce
            // source-sized layout bounds.
            let ax = axCandidate.flatMap {candidate -> ScreenshotVisualContainer? in
                let box = logical(candidate.bounds)
                return box.width <= source.width+line*0.5 && box.height <= source.height+line*0.5 ? nil : candidate
            }
            let visual = container(for:region.bounds)
            let control:ScreenshotVisualContainer?
            if let ax,let visual,visual.compact,visual.bounds.width*visual.bounds.height < ax.bounds.width*ax.bounds.height {control = visual}
            else {control = ax ?? visual}
            let padding = control?.compact == true ? max(2,min(5,logical(control!.bounds).height*0.09)) : max(2,line*0.15)
            let interior = control.map {logical($0.bounds).insetBy(dx:padding,dy:padding)} ?? canvas
            // Source text supplies a baseline and a starting point, never a
            // width allowance. Search all the way to the nearest real obstacle.
            let left = control?.compact == true ? interior.minX : max(interior.minX,source.minX-2)
            var right = interior.maxX,bottom = interior.minY,top = min(interior.maxY,source.maxY+2)
            if control?.compact == true {top = interior.maxY}
            var kind = control == nil ? "image-edge" : "container"
            let band = source.insetBy(dx:0,dy:-max(1,line*0.12))
            var obstacles = document.regions.filter {$0.id != region.id}.map {($0.bounds,"text")}
            obstacles += document.protectedBounds.map {($0,"graphic")}
            obstacles += (containers+semantic).filter {$0.compact && !$0.bounds.contains(CGPoint(x:region.bounds.midX,y:region.bounds.midY))}.map {($0.bounds,"control")}
            // Use the obstacle's near edge, not the midpoint of the empty gap.
            // OCR, graphics and controls participate even without a container.
            for (bounds,reason) in obstacles {
                let r = logical(bounds),overlap = min(band.maxY,r.maxY)-max(band.minY,r.minY)
                if r.minX >= source.maxX-2,r.midX > source.midX,overlap > min(source.height,r.height)*0.15,r.minX-padding < right {
                    right = r.minX-padding;kind = reason
                }
            }
            let raster = rasterRightEdge(source:source,limit:right)
            if raster < right {right = raster;kind = "pixel-edge"}
            var slotLeft = left
            if control?.compact == true {
                if let edge = rasterLeftEdge(source:source,limit:interior.minX) {slotLeft = max(slotLeft,edge)}
                for (bounds,_) in obstacles {
                    let r = logical(bounds)
                    if r.maxX <= source.minX+1,abs(r.midY-source.midY) < max(r.height,source.height)*0.8 {slotLeft = max(slotLeft,r.maxX+padding)}
                }
            }
            // Reserve vertical space against actual neighboring rows and rules,
            // so wrapping uses available space instead of a source-length ratio.
            for (bounds,_) in obstacles {
                let r = logical(bounds)
                guard r.maxX > slotLeft,r.minX < right else {continue}
                if r.maxY <= source.minY+1,r.midY < source.midY {bottom = max(bottom,r.maxY+padding)}
                else if r.minY >= source.maxY-1,r.midY > source.midY {top = min(top,r.minY-padding)}
            }
            bottom = max(bottom,rasterBottomEdge(source:source,left:slotLeft,right:right,limit:bottom))
            // Keep a valid source baseline if Vision boxes overlap by a pixel.
            bottom = min(bottom,source.minY);top = max(top,source.maxY)
            var slot = CGRect(x:slotLeft,y:bottom,width:max(1,right-slotLeft),height:max(1,top-bottom)).intersection(interior)
            region.centerVerticallyInViewport = control?.compact == true
            region.centeredInViewport = control?.compact == true && (control!.segment || abs(source.midX-slot.midX) < max(line*0.7,slot.width*0.13))
            let leftPixel = rasterLeftEdge(source:source,limit:max(interior.minX,source.minX-line*3))
            let leadingGraphic = (leftPixel.map {$0 > interior.minX+line*0.5} ?? false) || document.protectedBounds.contains {bounds in
                let r = logical(bounds)
                return r.maxX <= source.minX+1 && source.minX-r.maxX < line*3 && abs(r.midY-source.midY) < max(r.height,source.height)*0.8
            }
            if control == nil,!leadingGraphic,region.bounds.midX < 0.12 {
                let peers = document.regions.filter {abs($0.bounds.midX-region.bounds.midX)*CGFloat(width) < max(1,line*0.3) && $0.lineHeight/region.lineHeight > 0.75 && $0.lineHeight/region.lineHeight < 1.3}
                let widths = peers.map {$0.bounds.width*CGFloat(width)},lefts = peers.map {$0.bounds.minX*CGFloat(width)},rights = peers.map {$0.bounds.maxX*CGFloat(width)}
                let spread = (widths.max() ?? 0)-(widths.min() ?? 0)
                region.centeredInViewport = peers.count >= 3 && spread > line*0.75 && (lefts.max() ?? 0)-(lefts.min() ?? 0) > spread*0.4 && (rights.max() ?? 0)-(rights.min() ?? 0) > spread*0.4
                if region.centeredInViewport {
                    let half = min(source.midX-interior.minX,right-source.midX)
                    slot.origin.x = source.midX-half;slot.size.width = max(1,half*2)
                }
            }
            let final = slot.intersection(canvas)
            region.viewport = CGRect(x:final.minX/CGFloat(width),y:final.minY/CGFloat(height),width:final.width/CGFloat(width),height:final.height/CGFloat(height))
            region.rightBoundaryKind = kind
            return region
        }
        return ScreenshotDocument(regions:regions,protectedBounds:document.protectedBounds)
    }
    // Pixel coordinates here are bottom-left, matching the OCR/layout system.
    private func uprightColor(_ x:Int,_ y:Int) -> (Int,Int,Int) {color(x,height-1-y)}
    private func verticalInkEdge(_ x:Int,_ lo:Int,_ hi:Int) -> (strong:Bool,soft:Bool,weak:Bool) {
        var strong = 0,soft = 0,weak = 0,total = 0
        for y in lo...hi {
            let change = max(distance(uprightColor(x-1,y),uprightColor(x+1,y)),distance(uprightColor(x-2,y),uprightColor(x,y)))
            total += 1;if change >= 18 {strong += 1};if change >= 5 {soft += 1};if change >= 2 {weak += 1}
        }
        return (strong >= max(2,Int(ceil(CGFloat(total)*0.25))),soft >= max(3,Int(ceil(CGFloat(total)*0.8))),weak >= max(3,Int(ceil(CGFloat(total)*0.8))))
    }
    private func rasterRightEdge(source:CGRect,limit:CGFloat) -> CGFloat {
        let lo = max(1,Int(source.minY)),hi = min(height-2,Int(source.maxY))
        // The derivative reads x-2. Tight text boxes omit faint antialiasing
        // at their edge; leave that pixel behind before scanning for obstacles.
        // Otherwise the label's own trailing stroke becomes its right border.
        let start = max(2,Int(ceil(source.maxX))+3),end = min(width-3,Int(floor(limit)))
        guard end >= start,hi >= lo else {return limit}
        // Partial high-contrast strokes stop at graphics/text; full-height
        // low-contrast transitions stop at borders on dark surfaces.
        for x in start...end {
            let evidence = verticalInkEdge(x,lo,hi)
            if evidence.strong || (nativeEdges == nil && evidence.soft) {return max(source.maxX,CGFloat(x)-3)}
            if evidence.weak,let edge = nativeEdges?.edge(near:x,source:source,limit:limit,trailing:true) {return min(limit,edge)}
        }
        return limit
    }
    private func rasterLeftEdge(source:CGRect,limit:CGFloat) -> CGFloat? {
        let lo = max(1,Int(source.minY)),hi = min(height-2,Int(source.maxY))
        let start = min(width-3,Int(floor(source.minX))-3),end = max(2,Int(ceil(limit)))
        guard start >= end,hi >= lo else {return nil}
        for x in stride(from:start,through:end,by:-1) {
            let evidence = verticalInkEdge(x,lo,hi)
            if evidence.strong || (nativeEdges == nil && evidence.soft) {return min(source.minX,CGFloat(x)+3)}
            if evidence.weak,let edge = nativeEdges?.edge(near:x,source:source,limit:limit,trailing:false) {return max(limit,edge)}
        }
        return nil
    }
    private func rasterBottomEdge(source:CGRect,left:CGFloat,right:CGFloat,limit:CGFloat) -> CGFloat {
        let lo = max(1,Int(ceil(left))),hi = min(width-2,Int(floor(right)))
        let start = min(height-3,Int(floor(source.minY))-3),end = max(2,Int(ceil(limit)))
        guard start >= end,hi >= lo else {return limit}
        for y in stride(from:start,through:end,by:-1) {
            var strong = 0,total = 0
            for x in stride(from:lo,through:hi,by:2) {
                total += 1
                if distance(uprightColor(x,y-1),uprightColor(x,y+1)) >= 6 {strong += 1}
            }
            if strong >= max(3,Int(ceil(CGFloat(total)*0.72))) {return min(source.minY,CGFloat(y)+3)}
        }
        return limit
    }
    private func tileBehind(_ glyph:CGRect) -> Bool {
        let pad = max(2,glyph.height*0.18)
        let ring = [(glyph.minX-pad,glyph.midY),(glyph.maxX+pad,glyph.midY),(glyph.midX,glyph.minY-pad),(glyph.midX,glyph.maxY+pad)]
        if ring.filter({point in let c = color(Int(point.0),Int(point.1));return max(c.0,c.1,c.2)-min(c.0,c.1,c.2) > 14}).count >= 3 {return true}
        return components.contains {component in
            let r = component.rect,overlap = r.intersection(glyph)
            return component.area >= 30 && r.width/r.height > 0.6 && r.width/r.height < 1.6 && r.height >= glyph.height*0.96 && r.height < glyph.height*2.5
                && !overlap.isNull && overlap.width*overlap.height >= glyph.width*glyph.height*0.75 && edgeStrength(r) >= 0.5
        }
    }
    private func backgroundColor(_ r:CGRect) -> (Int,Int,Int) {color(Int(r.minX+r.width*0.5),Int(r.minY+2))}
    private func inkDensity(_ r:CGRect,background:(Int,Int,Int)) -> CGFloat {
        var ink = 0,total = 0
        for y in max(0,Int(r.minY))...min(height-1,Int(r.maxY)) {for x in max(0,Int(r.minX))...min(width-1,Int(r.maxX)) {total += 1;if distance(color(x,y),background) > 38 {ink += 1}}}
        return CGFloat(ink)/CGFloat(max(1,total))
    }
    // Outline navigation icons have no colored tile. Recover a repeated icon
    // column from pixels even when Vision folds each icon into its label. The
    // larger-than-text outlines are evidence; repeated letters in table cells
    // alone are not sufficient. No label vocabulary or OCR glyph is consulted.
    private func navigationGraphics(for lines:[ScreenshotTextLine]) -> [CGRect] {
        navigationRows = []
        struct Row {let icon:CGRect;let label:CGRect}
        var candidates:[Row] = []
        for line in lines where line.text.count >= 3 && line.text.count <= 48 {
            let r = pixelRect(line.bounds)
            guard r.minX < CGFloat(width)*0.45,r.width > r.height*1.8 else {continue}
            // The icon may be absent from OCR altogether, or a separate
            // observation. Inspect the preceding pixels as well as the line.
            let scanLeft = max(0,r.minX-r.height*3)
            let expanded = CGRect(x:scanLeft,y:r.minY-r.height*0.4,width:r.maxX+3-scanLeft,height:r.height*1.8).intersection(CGRect(x:0,y:0,width:width,height:height))
            let groups = inkGroups(in:expanded,padding:0)
            guard groups.count >= 2 else {continue}
            for i in 1..<groups.count {
                let icon = groups[..<i].reduce(CGRect.null) {$0.union($1)}
                let label = groups[i...].reduce(CGRect.null) {$0.union($1)}
                guard icon.minX < CGFloat(width)*0.2,label.minX-icon.maxX > max(3,label.height*0.3),icon.width/icon.height > 0.55,icon.width/icon.height < 1.65,
                      icon.height > label.height,icon.height < label.height*2,icon.width < label.width*1.5,
                      abs(icon.midY-label.midY) < icon.height*0.3 else {continue}
                candidates.append(Row(icon:icon,label:label));break
            }
        }
        var masks:[CGRect] = []
        for row in candidates {
            let peers = candidates.filter {other in
                abs(other.label.minX-row.label.minX) < row.label.height*0.35 && abs(other.icon.midX-row.icon.midX) < row.icon.height*0.35
                    && abs(other.label.midY-row.label.midY) > row.icon.height*1.4
            }
            guard peers.count >= 3 else {continue}
            let rail = peers+[row]
            guard rail.filter({$0.icon.height > $0.label.height*1.12}).count >= 3 else {continue}
            // A column of repeated literal values (for example A beside
            // lowercase descriptions) is not evidence of varied UI graphics.
            let shapes = Set(rail.map {candidate -> Int in
                let bg = backgroundColor(candidate.icon.insetBy(dx:-2,dy:-3))
                return Int((inkDensity(candidate.icon,background:bg)*40).rounded())
            })
            guard shapes.count >= 3 else {continue}
            // A column profile is supporting evidence, not permission to mask
            // every text line passing through its x coordinates. Every masked
            // row must independently have the outline and clear pixel gap.
            for candidate in rail {
                let mask = normalized(candidate.icon.insetBy(dx:-1.5,dy:-1.5))
                if !masks.contains(where: {$0.intersects(mask)}) {
                    masks.append(mask);navigationRows.append((mask,normalized(candidate.label)))
                }
            }
        }
        return masks
    }
    func navigationTextStart(for bounds:CGRect) -> CGFloat? {
        navigationRows.first {row in
            bounds.maxX > row.label.minX && abs(bounds.midY-row.icon.midY) < max(bounds.height,row.icon.height)*0.6
                && bounds.minX < row.label.minX+row.icon.width && bounds.height < row.icon.height*1.8
        }?.label.minX
    }
    func navigationRowIndex(for bounds:CGRect) -> Int? {
        navigationRows.firstIndex {row in
            bounds.maxX > row.icon.minX && bounds.minX < row.label.maxX
                && abs(bounds.midY-row.icon.midY) < max(bounds.height,row.icon.height)*0.6 && bounds.height < row.icon.height*1.8
        }
    }
    var navigationTextColumns:[CGRect] {
        var columns:[CGRect] = []
        for row in navigationRows {
            if let i = columns.firstIndex(where:{abs($0.minX-row.label.minX)*CGFloat(width) < max(2,row.label.height*CGFloat(height)*0.6)}) {
                columns[i] = columns[i].union(row.label)
            } else {columns.append(row.label)}
        }
        return columns
    }
    private func inkGroups(in r:CGRect,padding:CGFloat = 0.15) -> [CGRect] {
        let bg = backgroundColor(r),pad = max(0,Int(r.height*padding)),x0 = max(0,Int(r.minX)+pad),x1 = min(width-1,Int(r.maxX)-pad),y0 = max(0,Int(r.minY)+pad),y1 = min(height-1,Int(r.maxY)-pad)
        guard x1 > x0,y1 > y0 else {return []}
        var groups:[CGRect] = [],start:Int?,last = x0,low = y1,high = y0
        let blank = max(2,Int(ceil(r.height*0.1)))
        for x in x0...x1 {
            var ys:[Int] = []
            for y in y0...y1 where distance(color(x,y),bg) > 38 {ys.append(y)}
            if !ys.isEmpty {if start == nil {start = x;low = y1;high = y0};last = x;low = min(low,ys.first!);high = max(high,ys.last!)}
            else if let first = start,x-last >= blank {groups.append(CGRect(x:first,y:low,width:last-first+1,height:high-low+1));start = nil}
        }
        if let first = start {groups.append(CGRect(x:first,y:low,width:last-first+1,height:high-low+1))}
        return groups
    }
}
