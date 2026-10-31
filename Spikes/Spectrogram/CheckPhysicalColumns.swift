// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct CheckPhysicalColumns {
 static func main() {
  for style in [SpectrogramStripStyle.row,.pill] {
   for reduced in [false,true] {
    var ring=SpectrogramPixelRing(style:style,dark:false)
    var raster=[[UInt32]](repeating:[UInt32](repeating:0,count:style.rows),count:style.columns+2)
    ring.configure(dark:false,silent:false,reducedMotion:reduced) { raster[$0]=$1 }
    for step in 0..<600 {
     let slot=Int64(step+step/19+(step>=300 ? 1000000:0))
     let bands:[UInt8]?=step%11==0 ? nil : (0..<style.rows).map {UInt8((step+$0*7)%256)}
     ring.append(slot:slot,bands:bands,recorded:step%7 != 0) {raster[$0]=$1}
     if step%61==0 {
      ring.configure(dark:step%122==0,silent:step%183==0,reducedMotion:reduced) {raster[$0]=$1}
     }
     for column in 0..<(style.columns+2) {
      precondition(ring.columnPixels(at:column)==raster[column],"Raster mismatch: \(style) reduced=\(reduced) step=\(step) column=\(column)")
     }
    }
   }
  }
  print("PASS direct columns exactly match incremental rasters through wrap, gaps, off, palettes and Reduced Motion")
 }
}
