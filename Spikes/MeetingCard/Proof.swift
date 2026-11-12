// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Darwin

private func color(_ entry: CassiniTokens.Entry, _ dark: Bool) -> Color {
    Color(nsColor: entry.resolvedNSColor(dark: dark))
}

private struct RowContent: View {
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("Budget review").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text("09:00").font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(color(CassiniTokens.ink2Entry,dark))
            }
            Text("52 min · Marta, Dario, Speaker 3").font(.system(size: 11.5))
                .foregroundStyle(color(CassiniTokens.ink2Entry,dark)).lineLimit(1)
            Text("“We can keep the pilot small.”").font(.system(size: 11.5))
                .foregroundStyle(color(CassiniTokens.ink2Entry,dark)).lineLimit(1)
        }.frame(minHeight: 50, alignment: .top)
    }
}

private struct Board: View {
    let after: Bool
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(after ? "W2.3 · meeting card component" : "Before · extracted Library row renderer")
                .font(.system(size: 18, weight: .semibold))
            Text("Standalone proof · \(dark ? "dark" : "light") · same caller content")
                .font(.system(size: 12)).foregroundStyle(color(CassiniTokens.ink2Entry,dark))
            VStack(alignment: .leading, spacing: MeetingCard<EmptyView>.Metrics.interCardGap) {
                ForEach([false,true],id: \.self) { selected in
                    HStack(spacing: 16) {
                        Text(selected ? "Selected" : "Rest").font(.system(size: 11)).frame(width: 62,alignment: .leading)
                            .foregroundStyle(color(CassiniTokens.ink2Entry,dark))
                        if after {
                            MeetingCard(isSelected: selected) { RowContent(dark: dark) }.frame(width: 384)
                        } else {
                            LegacyCard(selected: selected,meeting: LibraryMeeting(title:"Budget review",meta:"52 min · Marta, Dario, Speaker 3",quote:"We can keep the pilot small."))
                                .frame(width:384)
                        }
                    }
                }
            }.padding(.vertical,12)
            Text("Surface only. No Library wiring, keyboard test or row-anatomy change.")
                .font(.system(size:11)).foregroundStyle(color(CassiniTokens.ink2Entry,dark))
        }.padding(24).frame(width:560,alignment:.leading)
            .foregroundStyle(color(CassiniTokens.inkEntry,dark))
            .background(color(CassiniTokens.sunkenEntry,dark))
    }
}

@main private struct Proof {
    private struct Failure: Error { let message:String }
    private static func require(_ good:Bool,_ message:String) throws { if !good { throw Failure(message:message) } }
    @MainActor private static func image<V:View>(_ view:V,_ dark:Bool,_ label:String = "view") throws -> CGImage {
        let renderer=ImageRenderer(content:view.environment(\.colorScheme,dark ? .dark : .light))
        renderer.scale=2;renderer.colorMode = .nonLinear
        guard let image=renderer.cgImage else { throw Failure(message:"No native image: \(label)") };return image
    }
    private static func pixels(_ image:CGImage) -> [UInt8] {
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        bytes.withUnsafeMutableBytes { buffer in
            let context=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        };return bytes
    }
    private static func rgb(_ entry:CassiniTokens.Entry,_ dark:Bool) -> [Double] {
        let value=dark ? entry.darkRGB : entry.lightRGB
        return [Double((value>>16)&255),Double((value>>8)&255),Double(value&255)]
    }
    private static func mix(_ a:[Double],_ p:Double,_ b:[Double]) -> [Double] { zip(a,b).map { $0*p+$1*(1-p) } }
    @MainActor static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("Card proof failed: \(error)\n".utf8));exit(1) }
    }
    @MainActor private static func run() throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        var results:[[String:Any]]=[]
        for dark in [false,true] {
            var error:Error?
            NSAppearance(named:dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                do {
                    for selected in [false,true] {
                        let blank=MeetingCard(isSelected:selected) { Rectangle().fill(color(CassiniTokens.surfaceEntry,dark).opacity(0)).frame(height:50) }.frame(width:300).padding(14)
                        let cg=try image(blank,dark);let rgba=pixels(cg)
                        try require(cg.width==656 && cg.height==192,"Card padding or border geometry changed")
                        let surface=rgb(CassiniTokens.surfaceEntry,dark),ink=rgb(CassiniTokens.inkEntry,dark)
                        let fill=selected ? (dark ? mix(ink,0.06,surface) : surface) : rgb(CassiniTokens.cardRestEntry,dark)
                        let border=selected ? mix(ink,dark ? 0.5 : 0.55,surface) : rgb(CassiniTokens.lineEntry,dark)
                        func pixel(_ x:Int,_ y:Int) -> [UInt8] { let i=(y*cg.width+x)*4;return Array(rgba[i..<i+4]) }
                        func matches(_ pixel:[UInt8],_ expected:[Double]) -> Bool {
                            pixel[3]==255 && (0..<3).allSatisfy { abs(Double(pixel[$0])-expected[$0])<=1 }
                        }
                        try require(matches(pixel(328,96),fill),"Wrong card fill")
                        try require(matches(pixel(328,28),border),"Wrong card border")
                        try require(matches(pixel(328,30),selected ? border : fill),"Selected inset stroke is missing")
                        let insetProbe=MeetingCard(isSelected:selected) {
                            Rectangle().fill(color(CassiniTokens.inkEntry,dark)).frame(width:100,height:50)
                        }.frame(width:300).padding(14)
                        let insetImage=try image(insetProbe,dark,"inset"),insetBytes=pixels(insetImage)
                        func insetPixel(_ x:Int,_ y:Int) -> [UInt8] {
                            let offset=(y*insetImage.width+x)*4;return Array(insetBytes[offset..<offset+4])
                        }
                        try require(matches(insetPixel(50,96),ink) && matches(insetPixel(49,96),fill),
                                    "Wrong horizontal content inset")
                        try require(matches(insetPixel(60,46),ink) && matches(insetPixel(60,45),fill),
                                    "Wrong vertical content inset")
                        let stack=VStack(spacing:MeetingCard<EmptyView>.Metrics.interCardGap) { blank;blank }
                        // Each probe includes 28pt external proof padding. Production
                        // cards are 68pt high, separated by the named 6pt gap.
                        let stackImage=try image(stack,dark,"stack")
                        try require(stackImage.height==396,"Unexpected card stack geometry")
                        // Shadow must exist outside the shape only for selected light.
                        let outside=(0..<28).contains { pixel(328,$0)[3]>0 } || (164..<192).contains { pixel(328,$0)[3]>0 }
                        try require(outside == (selected && !dark),"Wrong card shadow state")
                        if !selected || dark { try require(pixel(28,28)[3]==0,"Card corner is not rounded") }
                        let content=MeetingCard(isSelected:selected) { Text("Budget review").font(.system(size:13)) }.frame(width:300).padding(14)
                        let ordinary=try image(content.foregroundStyle(color(CassiniTokens.inkEntry,dark)),dark)
                        let inherited=try image(content.foregroundStyle(color(CassiniTokens.onAccentEntry,dark)),dark)
                        try require(pixels(ordinary)==pixels(inherited),"Card inherited selection ink")
                        results.append(["dark":dark,"selected":selected,"fillPixels":true,"borderPixels":true,"insetPixels":true,"shadowPixels":true,"foregroundInvariant":true])
                    }
                    for after in [false,true] {
                        let cg=try image(Board(after:after,dark:dark),dark)
                        try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!
                            .write(to:output.appendingPathComponent("\(after ? "after" : "before")-\(dark ? "dark" : "light").png"))
                    }
                } catch let caught { error=caught }
            }
            if let error { throw error }
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("checks.json"))
        print("Four native card states pass geometry, fill/border/inset, shadow and ink checks")
    }
}
