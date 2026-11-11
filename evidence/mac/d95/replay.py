#!/usr/bin/env python3
"""Replay D95 behavioral checks in a private source/build tree."""
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parents[3]
out = Path(os.environ['D95_EVIDENCE_DIR']).expanduser().resolve()
assert root not in (out, *out.parents), 'Evidence must be outside the checkout'
assert os.environ.get('CASSINI_OPUS_ASSETS'), 'Use verified test Opus assets'
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='cassini-d95-') as temp:
    work = Path(temp) / 'source'
    work.mkdir()
    archive = Path(temp) / 'source.tar'
    archive.write_bytes(subprocess.check_output(['git', '-C', str(root), 'archive', 'HEAD']))
    with tarfile.open(archive) as tar:
        tar.extractall(work)
    build = Path(temp) / 'build'
    base = ['swift', 'test', '--scratch-path', str(build), '--jobs', '4']

    def run(name, command, mutation=False, cwd=work):
        log = out / (name + '.log')
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, timeout=600)
        if mutation:
            text = log.read_text()
            assert result.returncode != 0 and any('recorded an issue' in line and 'Expectation failed' in line for line in text.splitlines()), name
            assert 'Asynchronous wait failed' not in text and 'SWIFT TASK CONTINUATION MISUSE' not in text, name
        else:
            assert result.returncode == 0, (name, log)
        print(name, 'passed', flush=True)

    run('after', base + ['--filter', 'CassiniKitTests|CassiniLibraryTests|CassiniExportTests|CassiniSearchTests|CassiniRecordingTests',
                         '--skip', 'recordingAccessFollowsRenamedBookmarkAndFailsDuringMovePublication'])
    for profile in ('full', 'metadata'):
        adapter = str(build / 'debug/cassini-inspect') + (' --metadata' if profile == 'metadata' else '')
        run('conformance-' + profile, ['python3', 'run-conformance.py', '--adapter', adapter, '--profile', profile],
            cwd=work / 'Tests/CassiniKitTests/Conformance')
    mutations = [
        ('utc-priority', 'Sources/CassiniKit/MeetingTime.swift',
         'if let value=meeting?.recordedAtUtc', 'if false, let value=meeting?.recordedAtUtc', 'RecordingTimeReaderTests'),
        ('utc-mirror', 'Sources/CassiniKit/PortableMeetingTags.swift',
         'if let utc = model.meeting.recordedAtUtc { scalarTags.append(("CASSINI_RECORDED_AT_UTC",utc)) }',
         'if false, let utc = model.meeting.recordedAtUtc { scalarTags.append(("CASSINI_RECORDED_AT_UTC",utc)) }',
         'receivedExportsPreserveOnlyTheKnownRecordingTime'),
        ('utc-sanitization', 'Sources/CassiniExport/MeetingFileExporter.swift',
         'MeetingTime.normalizedUTC(value) == value', 'true', 'receivedExportsDropMalformedUTC'),
        ('manifest-trust', 'Sources/CassiniKit/MeetingTime.swift',
         'guard state != .invalidCassiniMetadata,state != .unknownCassiniFormat else {return nil}',
         'guard true else {return nil}', 'unreadableCassiniDoesNotBorrowDATE'),
        ('midnight-day-end', 'Sources/CassiniSearch/SearchIndex.swift',
         'date < day.end', 'date < calendar.date(byAdding:.day,value:1,to:day.start)!', 'midnightDSTUsesCalendarDayBounds'),
        ('rfc3339-case', 'Sources/CassiniKit/MeetingTime.swift',
         '[Tt ]', '[T ]', 'lowercaseRFC3339RecordingTimesAreInstants|lowercaseCreationTimesNeverLeakThroughDATE|lowercaseRecordingUTCReexportsAndReimports'),
        ('non-ok-copy', 'Sources/CassiniExport/MeetingFileExporter.swift',
         'if file.state != .ok && file.state != .plainAudio {', 'if false {', 'nonOKDocumentsArePreservedByteForByte|nonOKConformanceFilesExportUnchanged'),
        ('day-partition', 'Sources/CassiniLibrary/Meeting.swift',
         'time.flatMap(format.dayKey).map {"day:"+$0} ?? unknown', 'time.flatMap(format.dayKey).map {"day:"+$0+String(groups.count)} ?? unknown', 'mixedRecordingAndCreationTimesFormUniqueLocalizedSections'),
        ('unknown-date-catalog', 'Sources/CassiniLibrary/Meeting.swift',
         'LibraryLocalization.shared.text("library.group.unknownDate",language:format.language,locale:format.locale)',
         '"Date unknown"', 'mixedRecordingAndCreationTimesFormUniqueLocalizedSections'),
        ('calendar-day', 'Sources/CassiniKit/MeetingTime.swift',
         'return (1...days[n[1]-1]).contains(n[2])','return (1...31).contains(n[2])','impossibleInstantsCannotOverrideAValidDATE|invalidUTCDoesNotReplaceDistinctDATEOnReadExportOrReimport'),
        ('clock-hour', 'Sources/CassiniKit/MeetingTime.swift',
         '(0...23).contains(n[3])','(0...24).contains(n[3])','impossibleInstantsCannotOverrideAValidDATE|invalidUTCDoesNotReplaceDistinctDATEOnReadExportOrReimport'),
        ('fraction-equality', 'Sources/CassiniKit/MeetingTime.swift',
         'var fraction=fraction','var fraction=String(self.fraction.prefix(3))','fractionalCreationComparisonDoesNotRoundToMilliseconds|fractionalDATEPreservesItsMeaningThroughExportAndReimport'),
        ('raw-reader-value', 'Sources/CassiniKit/MeetingTime.swift',
         'return .init(source:.recordedAtUtc,value:value,instant:parsed.date)','return .init(source:.recordedAtUtc,value:normalizedUTC(value)!,instant:parsed.date)','lowercaseRFC3339RecordingTimesAreInstants'),
        ('canonical-copy', 'Sources/CassiniExport/MeetingFileExporter.swift',
         'MeetingTime.normalizedUTC(value) == value','MeetingTime.normalizedUTC(value) != nil','lowercaseRecordingUTCReexportsAndReimports'),
        ('canonical-creation', 'Sources/CassiniExport/MeetingFileExporter.swift',
         'original.flatMap({MeetingTime.canonicalUTC($0.meeting.createdAtUtc)})','original?.meeting.createdAtUtc','lowercaseRecordingUTCReexportsAndReimports'),
        ('civil-validation', 'Sources/CassiniKit/MeetingTime.swift',
         'isValidLocalLabel(label) {return .init','!label.isEmpty {return .init','malformedCivilLabelsNeverBecomeMeetingTime'),
        ('library-date-branch', 'Sources/CassiniLibrary/LibraryScanner.swift',
         'static func ordered(_ a: LibraryMeeting, _ b: LibraryMeeting) -> Bool {','static func ordered(_ a: LibraryMeeting, _ b: LibraryMeeting) -> Bool {\n        if let x=a.sortingInstant,let y=b.sortingInstant {return x==y ? identityOrdered(a,b) : x>y}', 'exactFractionOrderingDoesNotFallBackToRoundedDate'),
        ('search-date-branch', 'Sources/CassiniSearch/SearchIndex.swift',
         'if $0.meetingKey != $1.meetingKey {','if $0.meetingKey != $1.meetingKey {\n                if let a=meetings[$0.meetingKey]?.sortingInstant,let b=meetings[$1.meetingKey]?.sortingInstant {return a==b ? $0.meetingKey<$1.meetingKey : a>b}', 'preciseRecordingKeysOrderSearchHitsWithoutRoundedDateTies'),
        ('quicklook-created', 'Sources/CassiniLibrary/MeetingTimeFormatting.swift',
         'file.meetingTime.map { [absoluteDate($0)] } ?? []','file.manifest.flatMap {MeetingTime.parseInstant($0.meeting.createdAtUtc)}.map {[absoluteDate($0)]} ?? []','quickLookDateAssemblyUsesTheSharedRecordingTime'),
        ('unknown-subtitle-duration', 'Sources/CassiniLibrary/MeetingTimeFormatting.swift',
         '["day":unknownDate,"duration":durationMs.map {Self.meetingDuration($0,locale:locale,language:language)} ?? ""]','["day":unknownDate,"duration":""]','unknownDateKeepsDurationProvenanceAndHitPosition'),
    ]
    for name, file, old, new, test in mutations:
        path = work / file
        original = path.read_text()
        assert original.count(old) == 1, file
        try:
            path.write_text(original.replace(old, new))
            run('mutation-' + name, base + ['--filter', test], mutation=True)
        finally:
            path.write_text(original)
    run('restored', base + ['--filter', 'RecordingTimeReaderTests|MeetingTimeTests|MeetingTimeR2LibraryTests|RecordingTimeR2ExportTests|MeetingTimeSearchTests|MeetingExportTests|preciseRecordingKeysOrderSearchHitsWithoutRoundedDateTies'])
