// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CassiniLibrary

enum UXText {
    static var language: CassiniLanguage { .system }
    static var locale: Locale { .autoupdatingCurrent }
    static func mac(_ id:String,_ values:[String:String]=[:])->String {
        LibraryLocalization.shared.text("mac."+id,values,language:language,locale:locale)
    }
    static func text(_ id: String, _ values: [String: String] = [:]) -> String {
        LibraryLocalization.shared.text(id, values, language: language, locale: locale)
    }
}
