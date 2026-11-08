// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import CassiniModels

struct SpeechModelAdoptionTests {
    @Test func verifiedInstallationBecomesDefaultAndExplicitWhistleChoiceSurvivesRelaunch() {
        var model = SpeechModelAdoption()
        #expect(model.choice == .whistle)
        model.choose(.parakeet); #expect(model.choice == .whistle)
        model.verified("pin-A"); #expect(model.choice == .parakeet)
        model.choose(.whistle); model.verified("pin-A")
        #expect(model.choice == .whistle)
        var relaunched = SpeechModelAdoption(choice:model.choice,adoptedRevision:model.adoptedRevision)
        relaunched.verified("pin-A"); #expect(relaunched.choice == .whistle)
        relaunched.choose(.parakeet); #expect(relaunched.choice == .parakeet)
    }
    @Test func legacyWhistlePreferenceAdoptsOnceAndNewRevisionAdoptsAgain() {
        var model = SpeechModelAdoption(choice:.whistle)
        model.verified("pin-A"); #expect(model.choice == .parakeet)
        model.choose(.whistle); model.verified("pin-B")
        #expect(model.choice == .parakeet); #expect(model.adoptedRevision == "pin-B")
    }
    @Test func removalOrInvalidationFallsBackAndVerifiedReinstallAdopts() {
        var model = SpeechModelAdoption()
        model.verified("pin-A"); model.unavailable()
        #expect(model.choice == .whistle); #expect(model.adoptedRevision == nil)
        model.choose(.parakeet); #expect(model.choice == .whistle)
        model.verified("pin-A"); #expect(model.choice == .parakeet)
    }
    @Test func suggestionRequiresCapabilityDiskAndExplicitDownloadNotInstallationOrBusyState() {
        var suggestion = SpeechModelSuggestion()
        #expect(suggestion.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:false))
        #expect(!suggestion.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:true))
        suggestion.transcriptionFinished(engine:"whistle",succeeded:false)
        suggestion.transcriptionFinished(engine:"parakeet",succeeded:true)
        #expect(!suggestion.completedWhistle)
        suggestion.transcriptionFinished(engine:"whistle",succeeded:true)
        #expect(suggestion.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:true))
        #expect(!suggestion.show(capable:false,enoughDisk:true,installed:false,busy:false,afterFirst:true))
        #expect(!suggestion.show(capable:true,enoughDisk:false,installed:false,busy:false,afterFirst:true))
        #expect(!suggestion.show(capable:true,enoughDisk:true,installed:true,busy:false,afterFirst:true))
        #expect(!suggestion.show(capable:true,enoughDisk:true,installed:false,busy:true,afterFirst:true))
        #expect(suggestion.takeAfterFirst()); #expect(!suggestion.takeAfterFirst())
        let seen = SpeechModelSuggestion(completedWhistle:true,afterFirstShown:true)
        #expect(!seen.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:true))
        #expect(seen.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:false))
        suggestion.dismiss()
        let relaunched = SpeechModelSuggestion(completedWhistle:suggestion.completedWhistle,dismissed:suggestion.dismissed)
        #expect(!relaunched.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:false))
        #expect(!relaunched.show(capable:true,enoughDisk:true,installed:false,busy:false,afterFirst:true))
    }
    @Test func announcementIsClaimedOnceAndNeverOverridesExplicitChoice() {
        var existing = SpeechModelAdoption(choice:.parakeet)
        existing.verified("pin-A"); #expect(!existing.canAnnounce)
        var model = SpeechModelAdoption()
        model.verified("pin-A"); #expect(model.canAnnounce)
        var relaunched = SpeechModelAdoption(choice:model.choice,adoptedRevision:model.adoptedRevision,
            announcedRevision:model.announcedRevision,pendingAnnouncementRevision:model.pendingAnnouncementRevision)
        #expect(!relaunched.canAnnounce)
        relaunched.verified("pin-A"); #expect(relaunched.takeAnnouncement()); #expect(!relaunched.takeAnnouncement())
        relaunched.unavailable(); relaunched.verified("pin-A"); #expect(!relaunched.canAnnounce)
        relaunched.unavailable(); relaunched.verified("pin-B"); #expect(relaunched.canAnnounce)
        relaunched.choose(.whistle); #expect(!relaunched.takeAnnouncement())
    }
    @Test func suggestionUsesEightGiBArchitectureRuntimeAndTheExistingReserve() {
        func eligibility(_ memory: UInt64 = 8 << 30, arch: Bool = true, runtime: Bool = true,
                         disk: ModelDiskSpace? = .init(free:4 << 30,total:100 << 30)) -> ParakeetSuggestionEligibility {
            .init(physicalMemory:memory,architectureSupported:arch,runtimeAvailable:runtime,disk:disk,requiredStorage:1 << 30)
        }
        #expect(eligibility().capable && eligibility().enoughDisk)
        #expect(!eligibility((8 << 30)-1).capable)
        #expect(!eligibility(arch:false).capable); #expect(!eligibility(runtime:false).capable)
        #expect(!eligibility(disk:nil).enoughDisk)
        #expect(!eligibility(disk:.init(free:2 << 30,total:100 << 30)).enoughDisk)
    }

}
