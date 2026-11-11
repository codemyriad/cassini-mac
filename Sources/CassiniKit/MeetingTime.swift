// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// D95: an actual recording instant or an unzoned label, never an artifact stamp.
public struct MeetingTime: Sendable, Equatable {
    public enum Source:String,Sendable {case recordedAtUtc,date="DATE",recordedAtLocal}
    public let source:Source
    public let value:String
    public let instant:Date?
    /// One total-order representation for instants and sort-only civil components.
    public let orderingKey:String
    public init(instant:Date) {
        source = .recordedAtUtc;value=Self.utcString(instant);self.instant=instant
        orderingKey=Self.dateKey(instant)
    }
    private init(source:Source,value:String,instant:Date? = nil) {
        self.source=source;self.value=value;self.instant=instant
        orderingKey=Self.parsed(source == .recordedAtLocal ? value+"Z" : value)?.key ?? ""
    }
    public static func resolve(meeting:Meeting?,dateTag:String?) -> Self? {
        if let value=meeting?.recordedAtUtc,normalizedUTC(value) != nil,let parsed=parsed(value) {
            return .init(source:.recordedAtUtc,value:value,instant:parsed.date)
        }
        if let tag=dateTag,let date=parsed(tag),date.key != meeting.flatMap({parsed($0.createdAtUtc)?.key}) {
            return .init(source:.date,value:trimmed(tag),instant:date.date)
        }
        if let label=meeting?.recordedAtLocal,isValidLocalLabel(label) {return .init(source:.recordedAtLocal,value:label)}
        return nil
    }
    public static func utcString(_ date:Date) -> String {
        let f=ISO8601DateFormatter();f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        f.timeZone=TimeZone(secondsFromGMT:0);return f.string(from:date)
    }
    private static func trimmed(_ value:String) -> String {value.trimmingCharacters(in:.whitespacesAndNewlines)}
    /// Legacy DATE accepts the pinned reference reader's spaces and surrounding whitespace.
    /// Shape normalization never substitutes for strict calendar/clock/offset validation.
    public static func normalizedRFC3339(_ value:String) -> String? {
        let value=trimmed(value)
        guard !value.hasSuffix("-00:00"),value.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$"#,options:.regularExpression) != nil else {return nil}
        let normalized=String(value.prefix(10))+"T"+value.dropFirst(11).uppercased()
        return stamp(normalized) == nil ? nil : normalized
    }
    /// Read valid RFC3339 casing; producers write the returned canonical T/Z form.
    /// UTC fields do not borrow legacy DATE's whitespace/space-separator leniency.
    public static func normalizedUTC(_ value:String) -> String? {
        guard value==trimmed(value),value.utf8.count>=20,
              value.utf8.dropFirst(10).first != 32,
              let normalized=normalizedRFC3339(value),normalized.hasSuffix("Z") else {return nil}
        return normalized
    }
    public static func parseInstant(_ value:String) -> Date? {parsed(value)?.date}
    /// Canonical UTC output, retaining all fractional digits and the same instant.
    public static func canonicalUTC(_ value:String) -> String? {
        guard let parsed=parsed(value) else {return nil}
        let parts=utcParts(parsed.seconds)
        guard (1...9999).contains(parts.year) else {return nil}
        return text(parts,yearWidth:4)+(parsed.fraction.isEmpty ? "" : "."+parsed.fraction)+"Z"
    }
    public static func isValidLocalLabel(_ value:String) -> Bool {civilComponents(value) != nil}
    public var localComponents:DateComponents? {source == .recordedAtLocal ? Self.civilComponents(value) : nil}
    private static func civilComponents(_ value:String) -> DateComponents? {
        guard value.utf8.count==19,value.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#,options:.regularExpression) != nil else {return nil}
        let b=Array(value.utf8),n=fields(b)
        guard valid(n) else {return nil}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        return DateComponents(calendar:calendar,year:n[0],month:n[1],day:n[2],hour:n[3],minute:n[4],second:n[5])
    }
    public static func dateTag(recordedAtUtc:String?,createdAtUtc:String,legacy:String?) -> String {
        if let recordedAtUtc {return recordedAtUtc}
        if let legacy,let date=parsed(legacy),date.key != parsed(createdAtUtc)?.key {return legacy}
        return createdAtUtc
    }
    private struct Stamp {
        let seconds:Int64
        let fraction:String
        var key:String {
            var fraction=fraction
            while fraction.last=="0" {fraction.removeLast()}
            return MeetingTime.text(MeetingTime.utcParts(seconds),yearWidth:6)+"."+(fraction.isEmpty ? "0" : fraction)
        }
        var date:Date {
            let base=Double(seconds),next=Double(seconds+1)
            let fraction=Double("0."+fraction.prefix(16)) ?? 0
            // Date is display scaffolding. Never let floating rounding cross a day/second.
            return Date(timeIntervalSince1970:min(base+fraction,next.nextDown))
        }
    }
    private static func parsed(_ value:String) -> Stamp? {normalizedRFC3339(value).flatMap(stamp)}
    private static func fields(_ b:[UInt8]) -> [Int] {
        func n(_ a:Int,_ z:Int) -> Int {b[a..<z].reduce(0) {$0*10+Int($1-48)}}
        return [n(0,4),n(5,7),n(8,10),n(11,13),n(14,16),n(17,19)]
    }
    private static func valid(_ n:[Int]) -> Bool {
        guard (1...9999).contains(n[0]),(1...12).contains(n[1]),(0...23).contains(n[3]),(0...59).contains(n[4]),(0...59).contains(n[5]) else {return false}
        let leap=n[0]%4==0 && (n[0]%100 != 0 || n[0]%400==0)
        let days=[31,leap ? 29 : 28,31,30,31,30,31,31,30,31,30,31]
        return (1...days[n[1]-1]).contains(n[2])
    }
    private static func stamp(_ normalized:String) -> Stamp? {
        let b=Array(normalized.utf8),n=fields(b)
        guard valid(n) else {return nil}
        var end=19,fraction=""
        if b[end]==46 {
            end+=1;let first=end
            while b[end]>=48 && b[end]<=57 {end+=1}
            fraction=String(decoding:b[first..<end],as:UTF8.self)
        }
        var offset=0
        if b[end] != 90 {
            let h=Int(b[end+1]-48)*10+Int(b[end+2]-48),m=Int(b[end+4]-48)*10+Int(b[end+5]-48)
            guard h<=23,m<=59 else {return nil}
            offset=(h*3600+m*60)*(b[end]==45 ? -1 : 1)
        }
        let seconds=daysFromCivil(Int64(n[0]),Int64(n[1]),Int64(n[2]))*86400+Int64(n[3]*3600+n[4]*60+n[5]-offset)
        return .init(seconds:seconds,fraction:fraction)
    }
    // Proleptic Gregorian civil/epoch transforms: integer days, no lenient DateFormatter rollover.
    private static func daysFromCivil(_ year:Int64,_ month:Int64,_ day:Int64) -> Int64 {
        let y=year-(month<=2 ? 1 : 0),era=y/400,yoe=y-era*400
        let doy=(153*(month+(month>2 ? -3 : 9))+2)/5+day-1
        return era*146097+yoe*365+yoe/4-yoe/100+doy-719468
    }
    private typealias Parts=(year:Int64,month:Int64,day:Int64,hour:Int64,minute:Int64,second:Int64)
    private static func utcParts(_ seconds:Int64) -> Parts {
        let days=seconds>=0 ? seconds/86400 : (seconds-86399)/86400
        let clock=seconds-days*86400,z=days+719468,era=(z>=0 ? z : z-146096)/146097,doe=z-era*146097
        let yoe=(doe-doe/1460+doe/36524-doe/146096)/365
        var y=yoe+era*400
        let doy=doe-(365*yoe+yoe/4-yoe/100),mp=(5*doy+2)/153,d=doy-(153*mp+2)/5+1,m=mp+(mp<10 ? 3 : -9)
        y += m<=2 ? 1 : 0
        return (y,m,d,clock/3600,clock/60%60,clock%60)
    }
    private static func text(_ p:Parts,yearWidth:Int) -> String {
        String(format:yearWidth==6 ? "%06lld-%02lld-%02lldT%02lld:%02lld:%02lld" : "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld",p.year,p.month,p.day,p.hour,p.minute,p.second)
    }
    private static func dateKey(_ date:Date) -> String {
        let value=date.timeIntervalSince1970,floor=value.rounded(.down)
        guard value.isFinite,abs(floor)<1e15 else {return ""}
        var seconds=Int64(floor),nanoseconds=Int64(((value-floor)*1e9).rounded())
        if nanoseconds==1_000_000_000 {seconds+=1;nanoseconds=0}
        return Stamp(seconds:seconds,fraction:String(format:"%09lld",nanoseconds)).key
    }
}

extension CassiniFile {
    public var meetingTime:MeetingTime? {
        guard state != .invalidCassiniMetadata,state != .unknownCassiniFormat else {return nil}
        return MeetingTime.resolve(meeting:manifest?.meeting,dateTag:tags?["DATE"])
    }
}
