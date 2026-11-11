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
            assert result.returncode != 0 and 'recorded an issue' in text, name
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
         'if let utc = meeting?.recordedAtUtc', 'if false, let utc = meeting?.recordedAtUtc', 'RecordingTimeReaderTests'),
        ('utc-mirror', 'Sources/CassiniKit/PortableMeetingTags.swift',
         'if let utc = model.meeting.recordedAtUtc { scalarTags.append(("CASSINI_RECORDED_AT_UTC",utc)) }',
         'if false, let utc = model.meeting.recordedAtUtc { scalarTags.append(("CASSINI_RECORDED_AT_UTC",utc)) }',
         'receivedExportsPreserveOnlyTheKnownRecordingTime'),
        ('utc-sanitization', 'Sources/CassiniExport/MeetingFileExporter.swift',
         'value.hasSuffix("Z") && MeetingTime.parseInstant(value) != nil', 'true', 'receivedExportsDropMalformedUTC'),
        ('manifest-trust', 'Sources/CassiniKit/MeetingTime.swift',
         'guard state != .invalidCassiniMetadata, state != .unknownCassiniFormat else { return nil }',
         'guard true else { return nil }', 'unreadableCassiniDoesNotBorrowDATE'),
        ('midnight-day-end', 'Sources/CassiniSearch/SearchIndex.swift',
         'date < day.end', 'date < calendar.date(byAdding:.day,value:1,to:day.start)!', 'midnightDSTUsesCalendarDayBounds'),
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
    run('restored', base + ['--filter', 'RecordingTimeReaderTests|MeetingTimeTests|MeetingTimeSearchTests|MeetingExportTests'])
