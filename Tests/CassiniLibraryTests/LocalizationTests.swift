// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import CassiniKit
import Testing
@testable import CassiniLibrary

@Suite struct LocalizationTests {
    private func placeholders(_ text:String)->Set<String> {
        let regex=try! NSRegularExpression(pattern:#"\{([A-Za-z0-9_]+)\}"#)
        let value=text as NSString
        return Set(regex.matches(in:text,range:NSRange(location:0,length:value.length)).map {value.substring(with:$0.range(at:1))})
    }
    @Test func osLanguageAndPortugueseRegions() {
        let expected:[String:CassiniLanguage]=["en-GB":.en,"it-CH":.it,"fr-CA":.fr,"es-MX":.es,
            "pt":.ptBR,"pt-BR":.ptBR,"pt_br":.ptBR,"pt-PT":.ptPT,"pt-AO":.ptPT,"pt-MZ":.ptPT,
            "pt_BR@rg=dezzzz":.ptBR,"pt_PT@rg=uszzzz":.ptPT,"pt-CV":.ptPT,"pt-TL":.ptPT,"de-DE":.en,"zh-Hans-CN":.en,"":.en]
        for (tag,language) in expected {#expect(CassiniLanguage(languageTag:tag) == language,"Language \(tag)")}
    }
    @Test func cardinalCategoriesFollowCLDRIncludingVisibleFractionDigits() {
        let vectors:[(CassiniLanguage,String,String)]=[
            (.en,"0","other"),(.en,"1","one"),(.en,"1.0","other"),(.en,"2","other"),
            (.it,"0","other"),(.it,"1","one"),(.it,"1.0","other"),(.it,"1000000","many"),
            (.fr,"0","one"),(.fr,"0.5","one"),(.fr,"1.0","one"),(.fr,"1.9","one"),(.fr,"2","other"),(.fr,"1000000","many"),
            (.es,"1.0","one"),(.es,"1.1","other"),(.es,"1000000","many"),
            (.ptBR,"0","one"),(.ptBR,"1.5","one"),(.ptBR,"2","other"),(.ptBR,"1000000","many"),
            (.ptPT,"0","other"),(.ptPT,"1","one"),(.ptPT,"1.0","other"),(.ptPT,"1.5","other"),(.ptPT,"1000000","many"),
            (.fr,"1000000.0","other"),(.ptPT,"-1","one"),(.fr,"-0.5","one"),(.it,"1000001","other")]
        for (language,value,expected) in vectors {#expect(language.pluralCategory(value) == expected,"\(language.rawValue) \(value)")}
    }
    @Test func everyCatalogIDResolvesInAllSixLanguagesWithMatchingPlaceholders() throws {
        let catalog=LibraryLocalization.shared
        #expect(Set(catalog.entries.map(\.id)).count == catalog.entries.count)
        for entry in catalog.entries {
            let source=placeholders(entry.en),macSource=placeholders(entry.mac ?? entry.en)
            for language in CassiniLanguage.allCases {
                if language != .en {
                    let translated=try #require(entry.l10n?[language.rawValue],"\(entry.id) \(language.rawValue)")
                    #expect(placeholders(translated.text) == source,"\(entry.id) \(language.rawValue) text")
                    if let mac=translated.mac {#expect(placeholders(mac) == macSource,"\(entry.id) \(language.rawValue) mac")}
                    if let plural=entry.plural {
                        let forms=try #require(translated.plural)
                        #expect(Set(forms.keys) == language.pluralCategories,"\(entry.id) \(language.rawValue)")
                        for (category,text) in forms {
                            let tokens=placeholders(text)
                            #expect(tokens.isSubset(of:source),"Unexpected placeholder: \(entry.id) \(language) \(category)")
                            #expect(source.subtracting(["n","m"]).isSubset(of:tokens),"Lost non-count placeholder: \(entry.id)")
                            if category != "one" {#expect(tokens == placeholders(plural["other"]!),"\(entry.id) \(language) \(category)")}
                            if category == "one" && (language == .fr || language == .ptBR) {#expect(tokens.contains("n"),"Zero/one must preserve the actual count")}
                        }
                    }
                }
                for n in ["0","1","2","1000000"] {
                    let substitutions=Dictionary(uniqueKeysWithValues:source.union(macSource).map {($0,$0 == "n" ? n : ($0 == "m" ? "2" : "value-"+$0))})
                    let rendered=catalog.text(entry.id,substitutions,language:language,locale:Locale(identifier:language.rawValue))
                    #expect(!rendered.isEmpty,"\(entry.id) \(language)")
                    #expect(placeholders(rendered).isEmpty,"Unresolved placeholder: \(entry.id) \(language) \(rendered)")
                }
            }
        }
    }
    @Test func translatedPluralZeroAndPlatformCopyAreUsed() {
        let strings=LibraryLocalization.shared
        #expect(strings.text("settings.title",language:.fr) == "Réglages")
        #expect(strings.text("format.today",language:.it) == "Oggi")
        #expect(strings.text("savedVoices.row.meetingCount",["n":"0"],language:.fr) == "0 réunion")
        #expect(strings.text("savedVoices.row.meetingCount",["n":"0"],language:.ptBR) == "0 reunião")
        #expect(strings.text("savedVoices.row.meetingCount",["n":"0"],language:.ptPT) == "0 reuniões")
    }
    @Test func insertedTextIsNeverReinterpretedAsAnotherPlaceholder() throws {
        let data=Data(#"{"entries":[{"id":"test","en":"{title} in {folder}"}]}"#.utf8)
        let strings=try LibraryLocalization(data:data)
        #expect(strings.text("test",["title":"{folder}","folder":"Library"],language:.en) == "{folder} in Library")
    }
    @Test func localeFormattersPreserveTheRulesAndTranslateLabels() {
        let date=Date(timeIntervalSince1970:0),zone=TimeZone(secondsFromGMT:0)!
        let french=LibraryFormat(timeZone:zone,now:date,locale:Locale(identifier:"fr_FR"))
        #expect(french.dayGroup(date)=="Aujourd’hui")
        #expect(french.searchContext(date,durationMs:nil,positionMs:300000)=="Aujourd’hui, 00:00 · à 00:05:00")
        #expect(LibraryFormat.meetingDuration(59000,locale:Locale(identifier:"it_IT"))=="meno di 1 min")
        #expect(LibraryFormat.size(bytes:1_288_490_189,approximate:true,locale:Locale(identifier:"fr_FR"))=="environ 1,2 Go")
        #expect(LibraryFormat.size(bytes:458*1024,locale:Locale(identifier:"fr_FR"))=="458 Ko")
        #expect(LibraryFormat.position(Int64.max,locale:Locale(identifier:"fr_FR"))=="2562047788015:12:55")
    }
    @Test func storedSpeakerLabelsSurviveAnEditAndAreDisplayedVerbatim() throws {
        let fixture=try Fixture()
        let words:[String:Any]=["language":"fr","items":[["speaker":"remote","startMs":0,"endMs":100,"text":"Original words"]]]
        try JSONSerialization.data(withJSONObject:words).write(to:fixture.folder.appendingPathComponent("transcript.json"))
        try fixture.metadata { value in
            value["speakers"]=[["id":"remote","name":NSNull(),"provenance":"unnamed","colourIndex":0,"label":"Intervenant 1"]]
            value["transcript"]=["status":"done","reference":["kind":"sidecar","file":"transcript.json","format":"cassini.words.v1"]]
        }
        let writer=try MeetingMetadataWriter(directory:fixture.folder,id:fixture.id)
        try writer.transaction {$0["title"]="Edited title"}
        let result=try #require(LibraryScanner(root:fixture.root).scan().meetings.first)
        #expect(result.speakers.first?.displayName=="Intervenant 1")
        #expect(result.speakers.first?.name==nil)
        #expect(result.transcriptItems.first?.text=="Original words")
    }
    @Test(arguments:["Speaker 7","Intervenant 4","  Ana  "]) func receivedLabelsAreDisplayedExactlyAsWritten(label:String) throws {
        let fixture=try Fixture()
        let base=try Data(contentsOf:fixture.repository.appendingPathComponent("Tests/CassiniKitTests/Conformance/opus/001-minimal-v1.opus"))
        let parsed=try CassiniReader.read(base)
        var manifest=try #require(parsed.manifest?.raw)
        let original=try #require(manifest["speakers"]?.array?.first)
        let speaker=try #require(original["id"]?.string)
        manifest=try manifest.setting("speakers",to:.array([try original.setting("label",to:.string(label))]))
        let body=try JSONSerialization.data(withJSONObject:["language":"en","items":[["speaker":speaker,"startMs":0,"endMs":100,"text":"Stored words"]]])
        let source=fixture.root.appendingPathComponent("Received.opus")
        _=try OpusStreamFile.rewrite(base,tags:PortableMeetingTags.make(manifest:manifest,transcript:body,wordCount:1),to:source)
        let imported=try LibraryImport.copy(source,into:fixture.root.appendingPathComponent("Library"))
        #expect(imported.speakerNames==[label])
        #expect(imported.transcriptItems.map(\.text)==["Stored words"])
        let writer=try MeetingMetadataWriter(directory:imported.folder,id:imported.id)
        try writer.transaction {$0["title"]="Edited title"}
        #expect(try LibraryScanner(root:fixture.root.appendingPathComponent("Library")).scan().meetings.first?.speakerNames==[label])
    }
    @Test func everyLanguageHasNativePermissionCopyAndDeclaredBundleSupport() throws {
        let root=URL(fileURLWithPath:#filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist=try #require(PropertyListSerialization.propertyList(from:Data(contentsOf:root.appendingPathComponent("Cassini/Info.plist")),format:nil) as? [String:Any])
        #expect(Set(try #require(plist["CFBundleLocalizations"] as? [String])) == Set(CassiniLanguage.allCases.map(\.rawValue)))
        for language in CassiniLanguage.allCases {
            let url=root.appendingPathComponent("Cassini/Resources/Localization/\(language.rawValue).lproj/InfoPlist.strings")
            let strings=try #require(PropertyListSerialization.propertyList(from:Data(contentsOf:url),format:nil) as? [String:String])
            #expect(strings["NSMicrophoneUsageDescription"] == LibraryLocalization.shared.text("mac.permission.microphone",language:language))
            #expect(strings["NSAudioCaptureUsageDescription"] == LibraryLocalization.shared.text("mac.permission.audio",language:language))
        }
    }
    @Test func bundledAndApplicationCatalogsHaveTheExactCoordinatorDigest() throws {
        let root=URL(fileURLWithPath:#filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app=root.appendingPathComponent("Cassini/Resources/UX")
        let pin=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:app.appendingPathComponent("UPSTREAM.json"))) as? [String:String])
        let bytes=try Data(contentsOf:app.appendingPathComponent("strings.json"))
        let expected=try Data(contentsOf:root.appendingPathComponent("Sources/CassiniLibrary/Localization/strings.json"))
        #expect(bytes == expected)
        #expect(SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined() == pin["sha256"])
    }
}
