// SPDX-License-Identifier: GPL-3.0-or-later
// Deterministic installer artwork; Core Graphics/ImageIO only, no AppKit or UI.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let output=URL(fileURLWithPath:CommandLine.arguments[1])
let width=640,height=400
let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                      space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
context.setFillColor(CGColor(red:0.73,green:0.73,blue:0.73,alpha:1))
let arrow=CGMutablePath();arrow.move(to:CGPoint(x:278,y:108))
for p in [CGPoint(x:330,y:108),CGPoint(x:330,y:88),CGPoint(x:362,y:120),CGPoint(x:330,y:152),CGPoint(x:330,y:132),CGPoint(x:278,y:132)] {arrow.addLine(to:p)}
arrow.closeSubpath();context.addPath(arrow);context.fillPath()
let destination=CGImageDestinationCreateWithURL(output as CFURL,UTType.png.identifier as CFString,1,nil)!
CGImageDestinationAddImage(destination,context.makeImage()!,nil)
guard CGImageDestinationFinalize(destination) else {throw NSError(domain:"DMGBackground",code:1)}
print("Wrote640×400 installer background")
