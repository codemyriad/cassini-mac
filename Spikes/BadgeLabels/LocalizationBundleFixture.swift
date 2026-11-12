// SPDX-License-Identifier: GPL-3.0-or-later
// swiftc compiles the actual CassiniLibrary localization/format sources for the
// standalone proof. It never reads LibraryLocalization.shared; the presenter
// receives the exact pinned catalog Data instead of Bundle.module resources.
import Foundation
extension Bundle { static var module: Bundle { .main } }
