// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SpectrogramStripStyle: Sendable {
    case pill, row
    public var columns: Int { self == .pill ? 50 : 200 }
    public var rows: Int { self == .pill ? 16 : 32 }
    public var slotMs: Double { self == .pill ? 80 : 20 }
}
/// Premultiplied BGRA8 pixels for IOSurface. A lookup table is baked only when
/// appearance/warning changes; new columns never calculate pow or blend cells.
public struct SpectrogramPalette: Sendable {
    private let table: [UInt32]
    public let dot: UInt32
    public init(style: SpectrogramStripStyle, dark: Bool, silent: Bool) {
        let ink: UInt32 = style == .pill ? (dark ? 0xff6961 : 0xd70015) : (dark ? 0xf5f5f7 : 0x1d1d1f)
        let maximum = style == .pill ? 0.95 : (dark ? 0.88 : 0.90)
        let trough: UInt32 = silent ? (style == .pill ? 0xff9f0a : (dark ? 0xff9f0a : 0xc47a00)) : ink
        let floorAlpha = silent ? (style == .pill ? (dark ? 0.30 : 0.40) : (dark ? 0.20 : 0.24)) : (style == .pill ? (dark ? 0.13 : 0.12) : 0.06)
        table = (0...255).map { value in
            Self.composite(ink:ink,alpha:maximum*pow(Double(value)/255,1.35),trough:trough,troughAlpha:floorAlpha)
        }
        dot = Self.composite(ink:ink,alpha:style == .pill ? 0.55 : 0.40,trough:0,troughAlpha:0)
    }
    public func pixel(_ value: UInt8) -> UInt32 { table[Int(value)] }
    private static func composite(ink: UInt32, alpha: Double, trough: UInt32, troughAlpha: Double) -> UInt32 {
        func channel(_ colour: UInt32, _ shift: UInt32) -> Double { Double((colour>>shift)&255)/255 }
        func byte(_ value: Double) -> UInt32 { UInt32((min(1,max(0,value))*255).rounded(.toNearestOrEven)) }
        let behind = troughAlpha*(1-alpha), total = alpha+behind
        let red = byte(channel(ink,16)*alpha+channel(trough,16)*behind)
        let green = byte(channel(ink,8)*alpha+channel(trough,8)*behind)
        let blue = byte(channel(ink,0)*alpha+channel(trough,0)*behind)
        return byte(total)<<24 | red<<16 | green<<8 | blue
    }
}

/// Raw codes/slot identities only: the IOSurface is the sole RGBA image. Paint
/// touches newly released columns (and two clear guards), never full history
/// per display frame. Theme/reduced-motion changes explicitly rebake once.
public struct SpectrogramPixelRing {
    private enum State: UInt8 { case hole, recorded, notRecorded }
    public let style: SpectrogramStripStyle
    public var capacity: Int { style.columns+2 }
    public private(set) var latestSlot: Int64 = -1
    public private(set) var reducedMotion = false
    private var palette: SpectrogramPalette
    private var values: [UInt8], states: [UInt8], slots: [Int64]
    private let empty: [UInt32]
    public init(style: SpectrogramStripStyle, dark: Bool, silent: Bool = false) {
        self.style = style; palette = .init(style:style,dark:dark,silent:silent)
        values = [UInt8](repeating:0,count:(style.columns+2)*style.rows)
        states = [UInt8](repeating:0,count:style.columns+2)
        slots = [Int64](repeating:-1,count:style.columns+2)
        empty = [UInt32](repeating:0,count:style.rows)
    }
    /// Logical storage only; the native surface and object overhead are counted
    /// separately by the hosted view memory test.
    public var storageBytes: Int { values.count+states.count+slots.count*8+empty.count*4+256*4 }
    public mutating func configure(dark: Bool, silent: Bool, reducedMotion: Bool, paint: (Int,[UInt32]) -> Void) {
        palette = .init(style:style,dark:dark,silent:silent); self.reducedMotion = reducedMotion
        for index in 0..<capacity { paint(index,empty) }
        guard latestSlot >= 0 else { return }
        let width = reducedMotion ? style.columns : capacity
        for slot in max(0,latestSlot-Int64(width)+1)...latestSlot {
            let index = Int(slot%Int64(capacity))
            guard slots[index] == slot else { continue }
            paint(pixelIndex(slot),pixels(index:index,slot:slot))
        }
        clearAhead(paint)
    }
    /// A nil recorded column is a hole. An off side is dotted even without PCM;
    /// it must not be drawn as recorded silence. Gaps remain bounded after sleep.
    public mutating func append(slot: Int64, bands: [UInt8]?, recorded: Bool, paint: (Int,[UInt32]) -> Void) {
        precondition(slot >= 0 && (bands == nil || bands!.count == style.rows))
        guard slot > latestSlot else { return }
        let first = max(latestSlot+1,slot-Int64(capacity)+1)
        if first < slot { for missing in first..<slot { store(slot:missing,bands:nil,state:.hole,paint:paint) } }
        store(slot:slot,bands:bands,state:recorded ? (bands == nil ? .hole : .recorded) : .notRecorded,paint:paint)
        latestSlot = slot; clearAhead(paint)
    }
    public mutating func remember(slot: Int64, bands: [UInt8]?, recorded: Bool) {
        precondition(slot >= 0 && (bands == nil || bands!.count == style.rows))
        guard slot > latestSlot else { return }
        let first = max(latestSlot+1,slot-Int64(capacity)+1)
        if first < slot { for missing in first..<slot { record(slot:missing,bands:nil,state:.hole) } }
        record(slot:slot,bands:bands,state:recorded ? (bands == nil ? .hole : .recorded) : .notRecorded)
        latestSlot = slot
    }
    public func bandValues(at slot: Int64) -> [UInt8]? {
        guard slot >= 0 else { return nil }
        let index = Int(slot%Int64(capacity))
        guard slots[index] == slot, states[index] == State.recorded.rawValue else { return nil }
        return Array(values[index*style.rows..<(index+1)*style.rows])
    }
    /// Current native column without retaining a second full-colour ring.
    /// The raw slot identities, palette and two clear guards are shared with
    /// the incremental painter, including the Reduced Motion sweep.
    public func columnPixels(at column: Int) -> [UInt32] {
        precondition((0..<capacity).contains(column))
        guard latestSlot >= 0 else { return empty }
        let width = reducedMotion ? style.columns : capacity
        guard column < width else { return empty }
        let head = Int(latestSlot%Int64(width))
        guard column != (head+1)%width && column != (head+2)%width else { return empty }
        let age = (head-column+width)%width
        let slot = latestSlot-Int64(age)
        guard slot >= 0 else { return empty }
        let index = Int(slot%Int64(capacity))
        guard slots[index] == slot else { return empty }
        return pixels(index:index,slot:slot)
    }

    private func pixelIndex(_ slot: Int64) -> Int { Int(slot%Int64(reducedMotion ? style.columns : capacity)) }
    private mutating func store(slot: Int64, bands: [UInt8]?, state: State, paint: (Int,[UInt32]) -> Void) {
        record(slot:slot,bands:bands,state:state)
        paint(pixelIndex(slot),pixels(index:Int(slot%Int64(capacity)),slot:slot))
    }
    // History is also needed to pool a visible pill when no page row exists.
    // That path must not allocate or colourize discarded pixel columns.
    private mutating func record(slot: Int64, bands: [UInt8]?, state: State) {
        let index = Int(slot%Int64(capacity)); slots[index] = slot; states[index] = state.rawValue
        if let bands { values.replaceSubrange(index*style.rows..<(index+1)*style.rows,with:bands) }
    }
    private func pixels(index: Int, slot: Int64) -> [UInt32] {
        switch State(rawValue:states[index])! {
        case .hole: return empty
        case .recorded: return (0..<style.rows).map { palette.pixel(values[index*style.rows+style.rows-1-$0]) }
        case .notRecorded:
            let on = style == .pill ? slot%3 == 0 : slot%4 < 2
            guard on else { return empty }
            var pixels = empty
            pixels[style.rows/2] = palette.dot
            if style == .pill { pixels[style.rows/2-1] = palette.dot }
            return pixels
        }
    }
    private func clearAhead(_ paint: (Int,[UInt32]) -> Void) {
        guard latestSlot >= 0 else { return }
        paint(pixelIndex(latestSlot+1),empty); paint(pixelIndex(latestSlot+2),empty)
    }
}
