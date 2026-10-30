// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOSurface

public enum SpectrogramSurfaceError: Error { case allocation, locking(Int32) }

/// One surface bank for two lanes: 52x32 for the pill, 202x64 for page rows.
/// Native layers share it and crop their lane. Updates batch under one lock;
/// the display coordinator performs no lock or upload on scrolling-only frames.
@MainActor public final class SpectrogramSurface {
    public let surface: IOSurfaceRef
    public let width: Int, height: Int, bytesPerRow: Int, allocatedBytes: Int
    private let rowsPerLane: Int
    public init(style: SpectrogramStripStyle) throws {
        width = style.columns+2; rowsPerLane = style.rows; height = style.rows*2
        let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,width*4)
        let properties: [String:Any] = [
            kIOSurfaceWidth as String:width,kIOSurfaceHeight as String:height,
            kIOSurfaceBytesPerElement as String:4,kIOSurfaceBytesPerRow as String:stride,
            kIOSurfacePixelFormat as String:0x42475241
        ]
        guard let value = IOSurfaceCreate(properties as CFDictionary),
              IOSurfaceGetWidth(value) == width, IOSurfaceGetHeight(value) == height,
              IOSurfaceGetBytesPerElement(value) == 4,
              IOSurfaceGetBytesPerRow(value) >= width*4 else { throw SpectrogramSurfaceError.allocation }
        surface = value; bytesPerRow = IOSurfaceGetBytesPerRow(value); allocatedBytes = IOSurfaceGetAllocSize(value)
        try withWritableColumns { writer in writer.clear() }
    }
    /// Writer is valid only for this synchronous closure, like withUnsafeBytes.
    public func withWritableColumns(_ body: (Writer) -> Void) throws {
        let result = IOSurfaceLock(surface,[],nil)
        guard result == 0 else { throw SpectrogramSurfaceError.locking(result) }
        defer { IOSurfaceUnlock(surface,[],nil) }
        body(.init(buffer:.init(start:IOSurfaceGetBaseAddress(surface),count:allocatedBytes),
            width:width,bytesPerRow:bytesPerRow,rowsPerLane:rowsPerLane))
    }
    public struct Writer {
        private let buffer: UnsafeMutableRawBufferPointer
        private let width: Int, bytesPerRow: Int, rowsPerLane: Int
        fileprivate init(buffer: UnsafeMutableRawBufferPointer, width: Int, bytesPerRow: Int, rowsPerLane: Int) {
            self.buffer = buffer; self.width = width; self.bytesPerRow = bytesPerRow; self.rowsPerLane = rowsPerLane
        }
        public func clear() { buffer.initializeMemory(as:UInt8.self,repeating:0) }
        public func column(lane: SpectrogramLane, index: Int, pixels: [UInt32]) {
            SpectrogramSurface.writeColumn(buffer:buffer,width:width,bytesPerRow:bytesPerRow,
                rowsPerLane:rowsPerLane,lane:lane,index:index,pixels:pixels)
        }
    }
    /// Independently test the actual stride/packing routine on ordinary RAM;
    /// its unit tests never create a surface, window or graphics context.
    nonisolated static func writeColumn(buffer: UnsafeMutableRawBufferPointer, width: Int, bytesPerRow: Int,
                                        rowsPerLane: Int, lane: SpectrogramLane, index: Int, pixels: [UInt32]) {
        precondition(index >= 0 && index < width && pixels.count == rowsPerLane)
        precondition(bytesPerRow >= width*4 && buffer.count >= bytesPerRow*rowsPerLane*2)
        let firstRow = lane.rawValue*rowsPerLane
        for row in 0..<rowsPerLane {
            var value = pixels[row].littleEndian
            withUnsafeBytes(of:&value) { bytes in
                buffer.baseAddress!.advanced(by:(firstRow+row)*bytesPerRow+index*4).copyMemory(from:bytes.baseAddress!,byteCount:4)
            }
        }
    }
}
