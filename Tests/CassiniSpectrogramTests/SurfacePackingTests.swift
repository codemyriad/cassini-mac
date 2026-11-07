// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniSpectrogram

@Suite struct SurfacePackingTests {
    @Test func columnWritesOnlyItsLaneAndPreservesRowPaddingAndNeighbours() {
        let width = 5, stride = 32, rows = 16, bytes = stride*rows*2
        var storage = [UInt8](repeating:0xaa,count:bytes+8)
        storage.withUnsafeMutableBytes { raw in
            SpectrogramSurface.writeColumn(buffer:raw,width:width,bytesPerRow:stride,rowsPerLane:rows,
                lane:.others,index:2,pixels:[UInt32](repeating:0x11223344,count:rows))
        }
        for index in storage.indices {
            let row = index/stride, columnByte = index%stride
            if row >= rows && row < rows*2 && (8..<12).contains(columnByte) {
                #expect(storage[index] == [UInt8(0x44),0x33,0x22,0x11][columnByte-8],"BGRA little-endian pixels")
            } else { #expect(storage[index] == 0xaa,"Neighbouring columns, the other lane and trailing guards stay untouched") }
        }
    }
}
