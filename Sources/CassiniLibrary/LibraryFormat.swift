// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Explicit clocks/zones keep fixtures deterministic; formatters follow the user's locale.
public struct LibraryFormat: Sendable {
    public let timeZone: TimeZone
    public let now: Date
    public let locale: Locale
    public init(timeZone: TimeZone = .current, now: Date = Date(), locale: Locale = .current) { self.timeZone = timeZone; self.now = now; self.locale = locale }
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.locale = locale; c.timeZone = timeZone; return c }
    private func date(_ value: Date, template: String) -> String {
        let formatter = DateFormatter(); formatter.locale = locale
        formatter.calendar = calendar; formatter.timeZone = timeZone; formatter.setLocalizedDateFormatFromTemplate(template)
        // HARMONY's pinned British-English header omits the optional comma.
        if locale.identifier == "en_GB" && template == "EEEEdMMMMyyyy" {formatter.dateFormat="EEEE d MMMM yyyy"}
        return formatter.string(from:value)
    }
    private static func text(_ id:String,_ values:[String:String]=[:],locale:Locale,omitting:Set<String>=[])->String {
        LibraryLocalization.shared.text(id,values,language:.init(languageTag:locale.identifier),locale:locale,omitting:omitting)
    }
    private static func number(_ value:Int64,locale:Locale,padding:Int=1)->String {
        let formatter=NumberFormatter();formatter.locale=locale;formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator=false;formatter.minimumIntegerDigits=padding;formatter.maximumFractionDigits=0
        return formatter.string(from:NSNumber(value:value))!
    }
    public static func position(_ ms:Int64,locale:Locale = .current)->String {
        let s=max(0,ms)/1000
        return text("format.position",["hh":number(s/3600,locale:locale,padding:2),"mm":number((s/60)%60,locale:locale,padding:2),"ss":number(s%60,locale:locale,padding:2)],locale:locale)
    }
    public static func liveBadge(_ ms:Int64,locale:Locale = .current)->String {
        let s=max(0,ms)/1000
        if s>=3600 {return [number(s/3600,locale:locale),number((s/60)%60,locale:locale,padding:2),number(s%60,locale:locale,padding:2)].joined(separator:":")}
        return [number(s/60,locale:locale),number(s%60,locale:locale,padding:2)].joined(separator:":")
    }
    public static func liveBig(_ ms:Int64,locale:Locale = .current)->String {position(ms,locale:locale)}
    public static func meetingDuration(_ ms:Int64,locale:Locale = .current)->String {
        let m=max(0,ms)/60000
        if m==0 {return text("format.meetingDuration.underMinute",locale:locale)}
        if m<60 {return text("format.meetingDuration.minutes",["m":number(m,locale:locale)],locale:locale)}
        return text("format.meetingDuration.hours",["h":number(m/60,locale:locale),"mm":number(m%60,locale:locale,padding:2)],locale:locale)
    }
    public static func talkTime(_ ms:Int64,locale:Locale = .current)->String {
        let s=max(0,ms)/1000
        // h/min/s are invariant symbols in the shared glossary; numbers still
        // use the platform formatter. Full phrases come from the catalog.
        if s<60 {return number(s,locale:locale)+" s"}
        if s<3600 {return text("format.talkTime",["m":number(s/60,locale:locale),"s":number(s%60,locale:locale)],locale:locale)}
        return meetingDuration(ms,locale:locale)
    }
    public static func confirmedSpeech(_ ms:Int64,locale:Locale = .current)->String {
        text("format.confirmedSpeech",["duration":meetingDuration(ms,locale:locale)],locale:locale)
    }
    public func dayGroup(_ at:Date)->String {
        if calendar.isDate(at,inSameDayAs:now) {return Self.text("format.today",locale:locale)}
        if let yesterday=calendar.date(byAdding:.day,value:-1,to:now),calendar.isDate(at,inSameDayAs:yesterday) {return Self.text("format.yesterday",locale:locale)}
        return date(at,template:calendar.component(.year,from:at)==calendar.component(.year,from:now) ? "EEEEdMMMM" : "EEEEdMMMMyyyy")
    }
    public func rowTime(_ at:Date)->String {
        let formatter=DateFormatter();formatter.locale=locale
        formatter.timeZone=timeZone;formatter.dateStyle = .none;formatter.timeStyle = .short
        return formatter.string(from:at)
    }
    public func previewSubtitle(_ at:Date,durationMs:Int64?,received:Bool=false)->String {
        Self.text(received ? "format.previewSubtitle.received" : "format.previewSubtitle",
            ["day":dayGroup(at),"time":rowTime(at),"duration":durationMs.map {Self.meetingDuration($0,locale:locale)} ?? ""],
            locale:locale,omitting:durationMs == nil ? ["duration"] : [])
    }

    public func searchDate(_ at:Date)->String {
        if calendar.isDate(at,inSameDayAs:now) {return Self.text("format.today",locale:locale)}
        if let yesterday=calendar.date(byAdding:.day,value:-1,to:now),calendar.isDate(at,inSameDayAs:yesterday) {return Self.text("format.yesterday",locale:locale)}
        return date(at,template:calendar.component(.year,from:at)==calendar.component(.year,from:now) ? "dMMMM" : "dMMMMyyyy")
    }
    public func searchContext(_ at:Date,durationMs:Int64?,positionMs:Int64)->String {
        Self.text("format.searchContext",["day":dayGroup(at),"time":rowTime(at),"duration":durationMs.map {Self.meetingDuration($0,locale:locale)} ?? "",
            "position":Self.position(positionMs,locale:locale)],locale:locale,omitting:durationMs == nil ? ["duration"] : [])
    }
    public static func rowMeta(durationMs:Int64?,names:[String],locale:Locale = .current)->String {
        let first=names.prefix(3).joined(separator:", ")
        let namesText=names.count>3 ? text("format.rowMeta.overflow",["names":first,"k":String(names.count-3)],locale:locale) : first
        return [durationMs.map {meetingDuration($0,locale:locale)},namesText.isEmpty ? nil : namesText].compactMap {$0}.joined(separator:" · ")
    }
    public static func eta(_ minutes:Int64,locale:Locale = .current)->String {
        minutes<=0 ? text("states.badge.transcribing.underMinute",locale:locale) : text("states.badge.transcribing",["n":String(minutes)],locale:locale)
    }
    public static func searchCount(places:Int64,meetings:Int64)->String {
        "\(places) \(places == 1 ? "place" : "places") in \(meetings) \(meetings == 1 ? "meeting" : "meetings")"
    }
    public static func size(bytes:Int64,approximate:Bool=false,locale:Locale = .current)->String {
        let bytes=max(0,bytes),unit:Int64=1_048_576
        let mb=bytes/unit+(bytes%unit>=unit/2 ? 1 : 0),kb=bytes/1024+(bytes%1024>=512 ? 1 : 0)
        let value:String
        if bytes<unit && kb<1000 {value=text("format.size.kb",["n":String(bytes==0 ? 0 : max(1,kb))],locale:locale)}
        else if mb<1000 {value=text("format.size",["n":String(mb)],locale:locale)}
        else {
            let gb:Int64=1_073_741_824,fractional=(bytes%gb)*10
            let tenths=(bytes/gb)*10+fractional/gb+(fractional%gb>=gb/2 ? 1 : 0)
            let formatter=NumberFormatter();formatter.locale=locale;formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator=false;formatter.minimumFractionDigits=1;formatter.maximumFractionDigits=1
            let count=formatter.string(from:NSDecimalNumber(decimal:Decimal(tenths)/10))!
            let units=MeasurementFormatter();units.locale=locale;units.unitStyle = .short;units.unitOptions = .providedUnit
            value=[count,units.string(from:UnitInformationStorage.gigabytes)].joined(separator:" ")
        }
        return approximate ? text("format.size.approx",["size":value],locale:locale) : value
    }
}
