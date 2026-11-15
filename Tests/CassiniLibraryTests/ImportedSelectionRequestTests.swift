// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniLibrary

@Suite struct ImportedSelectionRequestTests {
    @Test func revealIsConsumedOnceAndReselectionCannotRequestItAgain() {
        var request = ImportedSelectionRequest()
        request.request("A")
        request.selectionChanged(to: ["A"], awaitingPublication: false)
        #expect(request.key == "A")
        request.consume("A")
        #expect(request.key == nil)
        request.selectionChanged(to: ["B"], awaitingPublication: false)
        request.selectionChanged(to: ["A"], awaitingPublication: false)
        #expect(request.key == nil)
    }

    @Test func failureCardPreservesRevealUntilConsumedOrSelectionSupersedesIt() {
        var request = ImportedSelectionRequest()
        request.request("A")
        request.consume("import-failure")
        #expect(request.key == "A")
        request.selectionChanged(to: ["B"], awaitingPublication: false)
        #expect(request.key == nil)
        request.selectionChanged(to: ["A"], awaitingPublication: false)
        #expect(request.key == nil)
    }

    @Test func scanGapPreservesRevealButLaterDeselectionAndMultiselectionCancelIt() {
        var request = ImportedSelectionRequest()
        request.request("A")
        request.selectionChanged(to: [], awaitingPublication: true)
        request.selectionChanged(to: ["B"], awaitingPublication: true)
        #expect(request.key == "A")
        request.selectionChanged(to: ["A"], awaitingPublication: true)
        request.selectionChanged(to: ["A"], awaitingPublication: false)
        #expect(request.key == "A")
        request.selectionChanged(to: [], awaitingPublication: false)
        #expect(request.key == nil)
        request.request("A")
        request.selectionChanged(to: ["A", "B"], awaitingPublication: false)
        #expect(request.key == nil)
    }

    @Test func relocationResetAndNewImportDiscardTheOldRequest() {
        var request = ImportedSelectionRequest()
        request.request("A")
        request.request("B")
        request.consume("A")
        #expect(request.key == "B")
        request.reset()
        request.selectionChanged(to: ["B"], awaitingPublication: false)
        #expect(request.key == nil)
    }
}
