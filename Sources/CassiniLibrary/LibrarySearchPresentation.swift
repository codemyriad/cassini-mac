// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves which meeting (and which toolbar controls) belong in the Library detail toolbar
/// so search previews never dispatch Star, Export, Find, or compact-header actions against
/// a hidden underlying meeting.
public enum LibraryDetailToolbarTarget: Sendable {
    case searchPreview(LibraryMeeting)
    case savedDetail(LibraryMeeting)
    case recording(LibraryMeeting)
    case none

    public static func resolve(
        searchVisible: Bool,
        searchPreviewMeeting: LibraryMeeting?,
        savedDetailMeeting: LibraryMeeting?,
        recordingSelected: Bool,
        selectedMeeting: LibraryMeeting?
    ) -> Self {
        if searchVisible, let preview = searchPreviewMeeting {
            return .searchPreview(preview)
        }
        if let saved = savedDetailMeeting {
            return .savedDetail(saved)
        }
        if recordingSelected, let recording = selectedMeeting {
            return .recording(recording)
        }
        return .none
    }

    public var meeting: LibraryMeeting? {
        switch self {
        case .searchPreview(let meeting), .savedDetail(let meeting), .recording(let meeting):
            return meeting
        case .none:
            return nil
        }
    }

    public var showsCompactHeader: Bool {
        if case .savedDetail = self { return true }
        return false
    }

    public var showsFindAction: Bool {
        if case .savedDetail = self { return true }
        return false
    }

    public var showsTrashAction: Bool {
        if case .savedDetail = self { return true }
        return false
    }
}

/// Pure state transitions for presenting and refocusing sidebar search across both
/// narrow floating-sidebar (< 920 pt) and wide split-view layouts.
public struct LibrarySidebarSearchPresentation: Equatable, Sendable {
    public var floatingSidebarOpen: Bool
    public var userHidSidebar: Bool
    public var showsSplitSidebar: Bool
    public var sidebarSearchPresented: Bool

    public enum FocusTarget: Equatable, Sendable {
        case embeddedField
        case nativeSearchField
    }

    public init(
        floatingSidebarOpen: Bool = false,
        userHidSidebar: Bool = false,
        showsSplitSidebar: Bool = true,
        sidebarSearchPresented: Bool = false
    ) {
        self.floatingSidebarOpen = floatingSidebarOpen
        self.userHidSidebar = userHidSidebar
        self.showsSplitSidebar = showsSplitSidebar
        self.sidebarSearchPresented = sidebarSearchPresented
    }

    @discardableResult
    public mutating func requestFocus(isNarrowWindow: Bool) -> FocusTarget {
        if isNarrowWindow {
            floatingSidebarOpen = true
            return .embeddedField
        } else {
            userHidSidebar = false
            showsSplitSidebar = true
            sidebarSearchPresented = true
            return .nativeSearchField
        }
    }

    public mutating func didPickSearchResult() {
        if floatingSidebarOpen {
            floatingSidebarOpen = false
        }
    }

    public mutating func didDismissSearch() {
        sidebarSearchPresented = false
    }
}
