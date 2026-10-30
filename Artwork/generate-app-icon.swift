// SPDX-License-Identifier: GPL-3.0-or-later
// macOS rounded-square adaptation of gnome-cassini.svg (see UPSTREAM.json).
// Reproduce without launching an app: swift Artwork/generate-app-icon.swift Cassini/Assets.xcassets/AppIcon.appiconset
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[CGFloat((hex >> 16) & 255)/255,CGFloat((hex >> 8) & 255)/255,CGFloat(hex & 255)/255,alpha])!
}
func draw(_ pixels: Int) throws {
    let space = CGColorSpace(name:CGColorSpace.sRGB)!
    let context = CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels * 4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x:0,y:CGFloat(pixels)); context.scaleBy(x:CGFloat(pixels)/128,y:-CGFloat(pixels)/128)
    func rounded(_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat,_ radius: CGFloat,_ fill: CGColor) {
        context.setFillColor(fill); context.addPath(CGPath(roundedRect:CGRect(x:x,y:y,width:width,height:height),cornerWidth:radius,cornerHeight:radius,transform:nil));context.fillPath()
    }
    func circle(_ x: CGFloat,_ y: CGFloat,_ radius: CGFloat,_ fill: CGColor) {
        context.setFillColor(fill);context.fillEllipse(in:CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2))
    }
    let background = CGPath(roundedRect:CGRect(x:12,y:12,width:104,height:104),cornerWidth:23,cornerHeight:23,transform:nil)
    context.setShadow(offset:CGSize(width:0,height:2),blur:2,color:colour(0,0.18))
    context.setFillColor(colour(0x1c71d8));context.addPath(background);context.fillPath();context.setShadow(offset:.zero,blur:0,color:nil)
    context.saveGState();context.addPath(background);context.clip()
    let gradient = CGGradient(colorsSpace:space,colors:[colour(0x3584e4),colour(0x1c71d8)] as CFArray,locations:[0,1])!
    context.drawLinearGradient(gradient,start:CGPoint(x:64,y:12),end:CGPoint(x:64,y:116),options:[]);context.restoreGState()
    rounded(24,30,68,64,6,colour(0xffffff))
    circle(37,44,4,colour(0x9141ac));rounded(46,41,36,6,3,colour(0xc0bfbc))
    circle(37,60,4,colour(0xe66100));rounded(46,57,28,6,3,colour(0xc0bfbc));rounded(46,57,13,6,3,colour(0x99c1f1))
    circle(37,76,4,colour(0x26a269));rounded(46,73,22,6,3,colour(0xc0bfbc))
    circle(92,90,20,colour(0x1a5fb4));circle(92,88,20,colour(0xf6f5f4))
    context.setFillColor(colour(0x1c71d8));context.move(to:CGPoint(x:86,y:78));context.addLine(to:CGPoint(x:101,y:88));context.addLine(to:CGPoint(x:86,y:98));context.closePath();context.fillPath()
    let url = output.appendingPathComponent("icon-\(pixels).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
let sizes = [16,32,128,256,512]
var images: [[String:String]] = []
var generated = Set<Int>()
for size in sizes {
    for scale in [1,2] {
        let pixels = size * scale
        if generated.insert(pixels).inserted { try draw(pixels) }
        images.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":"icon-\(pixels).png"])
    }
}
try JSONSerialization.data(withJSONObject:["images":images,"info":["author":"xcode","version":1]],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("Contents.json"))
