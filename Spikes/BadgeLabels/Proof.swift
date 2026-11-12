// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Darwin

private struct Example {
    let name: String
    let input: BadgeLabelInput
    let oldKey: String
    var args: [String:String] = [:]
}
private let examples: [Example] = {
    var record=BadgeMeetingFields();record.lifecycle = .recording;record.liveMs=768000
    var saving=BadgeMeetingFields();saving.lifecycle = .saving
    var transcribing=BadgeMeetingFields();transcribing.transcript = .running;transcribing.etaMinutes=4
    var attention=BadgeMeetingFields();attention.error = .init(id:"fixture",action:"Retry")
    var interrupted=BadgeMeetingFields();interrupted.interruptedAtMs=2472000
    var received=BadgeMeetingFields();received.origin = .received;received.transcript = .done
    var noETA=transcribing;noETA.etaMinutes=nil
    var underMinute=transcribing;underMinute.etaMinutes=0
    return [.init(name:"recording",input:.meeting(record),oldKey:"recording",args:["liveBadge":"12:48"]),
            .init(name:"importing",input:.importingEntry,oldKey:"importing"),
            .init(name:"saving",input:.meeting(saving),oldKey:"saving"),
            .init(name:"transcribing",input:.meeting(transcribing),oldKey:"transcribing",args:["n":"4"]),
            .init(name:"attention",input:.meeting(attention),oldKey:"needsAttention"),
            .init(name:"interrupted",input:.meeting(interrupted),oldKey:"interrupted",args:["position":"00:41:12"]),
            .init(name:"received",input:.meeting(received),oldKey:"received"),
            .init(name:"no ETA",input:.meeting(noETA),oldKey:"transcribing.noEta"),
            .init(name:"under minute",input:.meeting(underMinute),oldKey:"transcribing.underMinute")]
}()

private struct Board: View {
    let after: Bool
    let dark: Bool
    let presenter: BadgeLabelPresenter
    let before: LibraryLocalization
    private func color(_ entry:CassiniTokens.Entry) -> Color { Color(nsColor:entry.resolvedNSColor(dark:dark)) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(after ? "W2.2 · merged W0.4 catalog and kinds" : "Before · current app catalog labels")
                .font(.system(size:18,weight:.semibold))
            Text("Standalone W2.1 renderer · \(dark ? "dark" : "light") · en-GB")
                .font(.system(size:12)).foregroundStyle(color(CassiniTokens.ink2Entry))
            ForEach(Array(examples.enumerated()),id:\.offset) { _,example in
                HStack(spacing:14) {
                    Text(example.name).font(.system(size:11)).frame(width:100,alignment:.leading)
                        .foregroundStyle(color(CassiniTokens.ink3Entry))
                    if after {
                        CatalogStatusBadge(presentation:presenter.presentation(for:example.input),isAnimating:false)
                    } else if before.contains("states.badge."+example.oldKey) {
                        let kind=StatusBadgeKind(rawValue:example.name=="no ETA" || example.name=="under minute" ? "transcribing" : example.name)!
                        MeetingStatusBadge(kind:kind,label:before.text("states.badge."+example.oldKey,example.args,language:.en,locale:Locale(identifier:"en_GB")),isAnimating:false)
                    } else {
                        Text("Not in baseline catalog").font(.system(size:11)).foregroundStyle(color(CassiniTokens.ink2Entry))
                    }
                    Spacer(minLength:0)
                }.frame(height:28)
            }
            Text("Label/kind proof only. No Library/Meeting wiring. Provisional ETA text retained.")
                .font(.system(size:11)).foregroundStyle(color(CassiniTokens.ink2Entry))
        }.padding(22).frame(width:660,alignment:.leading)
            .foregroundStyle(color(CassiniTokens.inkEntry)).background(color(CassiniTokens.groundEntry))
    }
}

@main private struct Proof {
    struct Failure: Error { let message:String }
    static func require(_ good:Bool,_ message:String) throws { if !good { throw Failure(message:message) } }
    @MainActor private static func image<V:View>(_ view:V,_ dark:Bool) throws -> CGImage {
        let renderer=ImageRenderer(content:view.environment(\.colorScheme,dark ? .dark : .light))
        renderer.scale=2;renderer.colorMode = .nonLinear
        guard let cg=renderer.cgImage else { throw Failure(message:"No native image") };return cg
    }
    private static func pixels(_ image:CGImage) -> [UInt8] {
        var result=[UInt8](repeating:0,count:image.width*image.height*4)
        result.withUnsafeMutableBytes { buffer in
            let context=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        };return result
    }
    private static func object(_ data:Data) throws -> [String:Any] { try JSONSerialization.jsonObject(with:data) as! [String:Any] }
    private static func fields(_ object:[String:Any]) throws -> BadgeMeetingFields {
        try JSONDecoder().decode(BadgeMeetingFields.self,from:JSONSerialization.data(withJSONObject:object))
    }
    private static func output(_ value:CatalogBadgePresentation?) -> Any {
        guard let value else { return NSNull() }
        return ["kind":value.kind,"text":value.text,"tint":value.tint,"glyph":value.glyph]
    }
    @MainActor static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("Badge label proof failed: \(error)\n".utf8));exit(1) }
    }
    @MainActor private static func run() throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let contract=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        let data=try Data(contentsOf:contract.appendingPathComponent("strings.json"))
        let presenter=try BadgeLabelPresenter(data:data,language:.en,locale:Locale(identifier:"en_GB"))
        let before=try LibraryLocalization(data:Data(contentsOf:folder.appendingPathComponent("inputs/before-strings.json")))
        let vectors=try object(Data(contentsOf:contract.appendingPathComponent("states-vectors.json")))
        var stateCount=0
        for vector in vectors["vectors"] as! [[String:Any]] {
            let f=try fields(vector["fields"] as! [String:Any]);let result=presenter.presentation(for:.meeting(f))
            try require(NSDictionary(dictionary:["badge":output(result)]).isEqual(to:["badge":vector["badge"]!]),"State vector mismatch: \(vector["id"]!)")
            if let expected=vector["canWriteDown"] as? Bool { try require(f.canWriteDown==expected,"Write-down policy changed") }
            stateCount+=1
        }
        for vector in vectors["entryVectors"] as! [[String:Any]] {
            try require(NSDictionary(dictionary:["badge":output(presenter.presentation(for:.importingEntry))]).isEqual(to:["badge":vector["badge"]!]),"Import entry mismatch")
        }
        let format=try object(Data(contentsOf:contract.appendingPathComponent("format-vectors.json")))
        for vector in format["eta"] as! [[String:Any]] {
            var f=BadgeMeetingFields();f.transcript = .running;f.etaMinutes=(vector["minutes"] as! NSNumber).int64Value
            try require(presenter.presentation(for:.meeting(f))?.text==vector["out"] as? String,"ETA format mismatch")
        }
        var rows=0
        for file in try FileManager.default.contentsOfDirectory(at:contract.appendingPathComponent("library-expected"),includingPropertiesForKeys:nil).filter({$0.pathExtension=="json"}) {
            for group in try object(Data(contentsOf:file))["groups"] as! [[String:Any]] {
                for row in group["meetings"] as! [[String:Any]] {
                    var f=try fields(row)
                    // Library snapshots expose elapsed recording time as display duration.
                    f.liveMs=(row["durationMs"] as? NSNumber)?.int64Value
                    try require(presenter.presentation(for:.meeting(f))?.text==row["badge"] as? String,"Library badge mismatch: \(file.lastPathComponent)")
                    rows+=1
                }
            }
        }
        // Compare every kind in each UI language against its pinned translation,
        // independently of the presenter-selected catalog key.
        let catalog=try object(data)["entries"] as! [[String:Any]]
        let entries=Dictionary(uniqueKeysWithValues:catalog.map { ($0["id"] as! String,$0) })
        var localized=0
        for language in CassiniLanguage.allCases {
            let locale=Locale(identifier:language == .en ? "en_GB" : language.rawValue)
            let p=try BadgeLabelPresenter(data:data,language:language,locale:locale)
            for example in examples {
                let entry=entries["states.badge."+example.oldKey]!
                let translation=language == .en ? entry : (entry["l10n"] as! [String:[String:Any]])[language.rawValue]!
                var expected=(language == .en ? translation["en"] : translation["text"]) as! String
                if example.oldKey=="transcribing" {
                    expected=(translation["plural"] as! [String:String])["other"]!
                }
                for (key,value) in example.args { expected=expected.replacingOccurrences(of:"{\(key)}",with:value) }
                // The new Interrupted entry has no position placeholder; replacement is harmless.
                try require(p.presentation(for:example.input)?.text==expected,"Localized badge mismatch: \(language.rawValue) / \(example.name)")
                localized+=1
            }
            for count in [Int64(1),1_000_000] {
                var f=BadgeMeetingFields();f.transcript = .running;f.etaMinutes=count
                let entry=entries["states.badge.transcribing"]!
                let t=language == .en ? entry : (entry["l10n"] as! [String:[String:Any]])[language.rawValue]!
                let category=language.pluralCategory(String(count))
                let forms=t["plural"] as! [String:String]
                let nf=NumberFormatter();nf.locale=locale;nf.numberStyle = .decimal
                let expected=(forms[category] ?? forms["other"]!).replacingOccurrences(of:"{n}",with:nf.string(from:NSNumber(value:count))!)
                try require(p.presentation(for:.meeting(f))?.text==expected,"Localized plural/count mismatch")
                localized+=1
            }
        }
        for language in [CassiniLanguage.en,.it] {
            let locale=Locale(identifier:"ar_EG")
            let p=try BadgeLabelPresenter(data:data,language:language,locale:locale)
            var f=BadgeMeetingFields();f.transcript = .running;f.etaMinutes=1000
            let entry=entries["states.badge.transcribing"]!
            let t=language == .en ? entry : (entry["l10n"] as! [String:[String:Any]])[language.rawValue]!
            let template=(t["plural"] as! [String:String])["other"]!
            let nf=NumberFormatter();nf.locale=locale;nf.numberStyle = .decimal
            try require(p.presentation(for:.meeting(f))?.text==template.replacingOccurrences(of:"{n}",with:nf.string(from:NSNumber(value:1000))!),"UI language and regional numbers were coupled")
            f.lifecycle = .recording;f.liveMs=768000
            let recording=entries["states.badge.recording"]!
            let base=language == .en ? recording["en"] as! String : ((recording["l10n"] as! [String:[String:Any]])[language.rawValue]!["text"] as! String)
            let clock=LibraryFormat.liveBadge(768000,locale:locale,language:language)
            try require(p.presentation(for:.meeting(f))?.text==base.replacingOccurrences(of:"{liveBadge}",with:clock),"Recording timer ignored regional digits")
            localized+=2
        }
        // Missing translations must not silently fall through to English.
        var broken=try object(data);var brokenEntries=broken["entries"] as! [[String:Any]]
        let index=brokenEntries.firstIndex { $0["id"] as? String=="states.badge.importing" }!
        var translations=brokenEntries[index]["l10n"] as! [String:Any];translations.removeValue(forKey:"fr")
        brokenEntries[index]["l10n"]=translations;broken["entries"]=brokenEntries
        var refused=false
        do { _=try BadgeLabelPresenter(data:JSONSerialization.data(withJSONObject:broken),language:.fr,locale:Locale(identifier:"fr_FR")) }
        catch BadgeLabelPresenter.InvalidCatalog.missingTranslation(_) { refused=true }
        try require(refused,"Missing translation silently fell back to English")
        for dark in [false,true] {
            for example in examples {
                let p=presenter.presentation(for:example.input)!
                let actual=try image(CatalogStatusBadge(presentation:p,isAnimating:false),dark)
                let visual=StatusBadgeKind(rawValue:example.name=="no ETA" || example.name=="under minute" ? "transcribing" : example.name)!
                let expected=try image(MeetingStatusBadge(kind:visual,label:p.text,isAnimating:false),dark)
                try require(actual.height==36 && pixels(actual)==pixels(expected),"Catalog view lost badge kind or label")
            }
            let anchor=Rectangle().fill(Color(nsColor:CassiniTokens.groundEntry.resolvedNSColor(dark:dark))).frame(width:100,height:30)
            let absent=try image(ZStack { anchor;CatalogStatusBadge(presentation:nil,isAnimating:false) },dark)
            try require(pixels(absent)==pixels(image(anchor,dark)),"Nil presentation rendered a badge")
            for after in [false,true] {
                let cg=try image(Board(after:after,dark:dark,presenter:presenter,before:before),dark)
                try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!
                    .write(to:folder.appendingPathComponent("\(after ? "after" : "before")-\(dark ? "dark" : "light").png"))
            }
        }
        let result:[String:Any]=["meetingVectors":stateCount,"importEntries":1,"libraryRows":rows,"etaVectors":3,"localizedCases":localized,"renderedCases":18,"nilViewCases":2,"missingTranslationRejected":true]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("checks.json"))
        print("W2.2: \(stateCount) states, 1 import, \(rows) rows, \(localized) localized cases, 18 native badges and nil views pass")
    }
}
