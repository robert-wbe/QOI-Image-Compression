//
//  ContentView.swift
//  Image Compression
//
//  Created by Robert Wiebe on 12/8/23.
//

import SwiftUI
import AppKit
import Cocoa

public struct Pixel: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    
    func hash() -> Int {
        (3*Int(r) + 5*Int(g) + 7*Int(b)) % 64
    }
    
    static func diff(lhs: Pixel, rhs: Pixel) -> Difference {
        return Difference(dr: Int(lhs.r)-Int(rhs.r), dg: Int(lhs.g)-Int(rhs.g), db: Int(lhs.b)-Int(rhs.b))
    }
    
    struct Difference {
        let dr: Int
        let dg: Int
        let db: Int
        
        init(dr: Int, dg: Int, db: Int) {
            self.dr = dr
            self.dg = dg
            self.db = db
        }
        
        var fitsSmall: Bool {
            -2 <= dr && 1 >= dr && -2 <= dg && 1 >= dg && -2 <= db && 1 >= db
        }
        
        var fitsMed: Bool {
            -32 <= dr && 31 >= dr && -8 <= dg && 7 >= dg && -8 <= db && 7 >= db
        }
    }
}

public struct PixelIterator: IteratorProtocol {
    let height: Int
    let width: Int
    
    var row: Int = 0
    var col: Int = 0
    
    init(height: Int, width: Int) {
        self.height = height
        self.width = width
    }
    
    public mutating func next() -> (Int, Int)? {
        if row >= height { return nil }
        let pixel = (row, col)
        col += 1
        if col >= width { row += 1; col = 0 }
        return pixel
    }
}

public struct ImageSize {
    let height: Int
    let width: Int
    
    init(height: Int, width: Int) {
        self.height = height
        self.width = width
    }
    init(fromNsSize nssize: NSSize) {
        height = Int(nssize.height)
        width = Int(nssize.width)
    }
}

extension NSImage: Sequence {
    func toPixels() -> [Pixel] {
        var returnPixels = [Pixel]()

        let pixelData = (self.cgImage(forProposedRect: nil, context: nil, hints: nil)!).dataProvider!.data
        let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)

        for y in 0..<Int(self.size.height) {
            for x in 0..<Int(self.size.width) {
                let pos = CGPoint(x: x, y: y)

                let pixelInfo: Int = ((Int(self.size.width) * Int(pos.y) * 4) + Int(pos.x) * 4)

                let r = data[pixelInfo]
                let g = data[pixelInfo + 1]
                let b = data[pixelInfo + 2]
                returnPixels.append(Pixel(r: r, g: g, b: b))
            }
        }
        return returnPixels
    }
    
    public struct Iterator: IteratorProtocol {
        public typealias Element = Pixel
        
        let data: UnsafePointer<UInt8>
        let imageSize: ImageSize
        var row: Int = 0
        var col: Int = 0
        
        init(_ image: NSImage) {
            let pixelData = image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider!.data
            data = CFDataGetBytePtr(pixelData)
            imageSize = ImageSize(fromNsSize: image.size)
        }
        
        public mutating func next() -> Pixel? {
            if row >= Int(imageSize.height) { return nil }

            let pixelInfo: Int = ((imageSize.width * row * 4) + col * 4)

            let r = data[pixelInfo]
            let g = data[pixelInfo + 1]
            let b = data[pixelInfo + 2]
            
            col += 1
            if col == imageSize.width { row += 1; col = 0 }
            
            return Pixel(r: r, g: g, b: b)
        }
    }
    
    public func makeIterator() -> Iterator {
        Iterator(self)
    }
    

    
}

struct QOI {
    static let rgbCode: UInt8 = 0b11111111
    static let runCode: UInt8 = 0b11000000
    static let smlCode: UInt8 = 0b01000000
    static let medCode: UInt8 = 0b10000000
    static let cheCode: UInt8 = 0b00000000
    
    static func encode(_ image: NSImage) -> [UInt8] {
        var buffer = [UInt8]()
        
        // storing the size in the first 4 bytes (height 2b | width 2b)
        let imageSize = ImageSize(fromNsSize: image.size)
        let (height, width) = (imageSize.height, imageSize.width)
        buffer.append(UInt8(height >> 8))
        buffer.append(UInt8(height % 256))
        buffer.append(UInt8(width >> 8))
        buffer.append(UInt8(width % 256))
        
        var cache = [Pixel](repeating: Pixel(r: 0, g: 0, b: 0), count: 64)
        var lastPixel = Pixel(r: 0, g: 0, b: 0)
        var itr = image.makeIterator()
        
        var currentPixel = itr.next()
        while let pixel = currentPixel {
            if pixel == lastPixel {
                // run is stored with bias 1
                var run: UInt8 = 0
                while run < 62 {
                    currentPixel = itr.next()
                    guard let pixel = currentPixel else { break }
                    if pixel != lastPixel { break }
                    run += 1
                }
                
                buffer.append(runCode + run)
                continue
            }
            
            let hash = pixel.hash()
            if cache[hash] == pixel {
                buffer.append(cheCode + UInt8(hash))
                lastPixel = pixel
                currentPixel = itr.next()
                continue
            }
            
            cache[hash] = pixel
            let df = Pixel.diff(lhs: pixel, rhs: lastPixel)
            lastPixel = pixel
            
            if df.fitsSmall {
                buffer.append(smlCode + UInt8(df.dr+2) << 4 + UInt8(df.dg+2) << 2 + UInt8(df.db+2))
                currentPixel = itr.next()
                continue
            }
            
            if df.fitsMed {
                buffer.append(medCode + UInt8(df.dr+32))
                buffer.append(UInt8(df.dg+8) << 4 + UInt8(df.db+8))
                currentPixel = itr.next()
                continue
            }
            
            // store raw RGB
            buffer.append(rgbCode)
            buffer.append(pixel.r)
            buffer.append(pixel.g)
            buffer.append(pixel.b)
            currentPixel = itr.next()
        }
        
        return buffer
    }
    
    static func decode(_ qoi: [UInt8]) -> [[Pixel]] {
        var bytes = qoi.makeIterator()
        let height = Int(bytes.next()!) << 8 + Int(bytes.next()!)
        let width = Int(bytes.next()!) << 8 + Int(bytes.next()!)
        var image: [[Pixel]] = .init(repeating: .init(repeating: Pixel(r: 0, g: 0, b: 0), count: width), count: height)
        var pixelItr = PixelIterator(height: height, width: width)
        
        var cache = [Pixel](repeating: Pixel(r: 0, g: 0, b: 0), count: 64)
        var lastPixel = Pixel(r: 0, g: 0, b: 0)
        
        while let byte = bytes.next() {
            if byte == rgbCode {
                let (row, col) = pixelItr.next()!
                let pixel = Pixel(r: bytes.next()!, g: bytes.next()!, b: bytes.next()!)
                image[row][col] = pixel
                cache[pixel.hash()] = pixel
                lastPixel = pixel
                continue
            }
            switch byte & 0b11000000 {
            case runCode:
                for _ in 0..<(Int(byte & 0b00111111)+1) {
                    let (row, col) = pixelItr.next()!
                    image[row][col] = lastPixel
                }
                continue
            case smlCode:
                let dr = Int((byte & 0b00110000) >> 4) - 2
                let dg = Int((byte & 0b00001100) >> 2) - 2
                let db = Int((byte & 0b00000011)) - 2
                let r = UInt8(Int(lastPixel.r) + dr)
                let g = UInt8(Int(lastPixel.g) + dg)
                let b = UInt8(Int(lastPixel.b) + db)
                let (row, col) = pixelItr.next()!
                let pixel = Pixel(r: r, g: g, b: b)
                image[row][col] = pixel
                cache[pixel.hash()] = pixel
                lastPixel = pixel
                continue
            case medCode:
                let dr = Int((byte & 0b00111111)) - 32
                let byte2 = bytes.next()!
                let dg = Int((byte2 & 0b11110000) >> 4) - 8
                let db = Int((byte2 & 0b00001111)) - 8
                let r = UInt8(Int(lastPixel.r) + dr)
                let g = UInt8(Int(lastPixel.g) + dg)
                let b = UInt8(Int(lastPixel.b) + db)
                let (row, col) = pixelItr.next()!
                let pixel = Pixel(r: r, g: g, b: b)
                image[row][col] = pixel
                cache[pixel.hash()] = pixel
                lastPixel = pixel
                continue
            case cheCode:
                let idx = Int(byte & 0b00111111)
                let (row, col) = pixelItr.next()!
                let pixel = cache[idx]
                image[row][col] = pixel
                lastPixel = pixel
                continue
            default:
                print("Error in switch")
            }
        }
        
        return image
    }
}

struct ContentView: View {
    let image = NSImage(named: NSImage.Name("SampleImg"))!
    let pixels: [Pixel]
    @State var secondImage: [[Pixel]]
    
    init() {
        pixels = image.toPixels()
        secondImage = .init(repeating: .init(repeating: Pixel(r: 0, g: 0, b: 0), count: Int(image.size.width)), count: Int(image.size.height))
    }
    
    var body: some View {
        VStack {
            Image(nsImage: image)
            Button("Encode") {
                let qoi = QOI.encode(image)
                let ogSize = image.size.width*image.size.height*3
                let cprSize = qoi.count
                print("Original size: \(image.size.width)x\(image.size.height) -> \(Int(ogSize)) bytes")
                print("Compressed size: \(qoi.count) bytes")
                let eff = 100 - 100*CGFloat(cprSize)/ogSize
                print("Compression Efficiency: \(eff)%")
                secondImage = QOI.decode(qoi)
            }
            Canvas { context, size in
                for row in 0..<Int(image.size.height){
                    for col in 0..<Int(image.size.width){
                        context.fill(
                            Path(CGRect(x: col, y: row, width: 1, height: 1)),
                            with: .color(Color(red: Double(secondImage[row][col].r)/255, green: Double(secondImage[row][col].g)/255, blue: Double(secondImage[row][col].b)/255)))
                    }
                }
            }
            .frame(width: image.size.width, height: image.size.height)
            .border(Color.white)
            
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
