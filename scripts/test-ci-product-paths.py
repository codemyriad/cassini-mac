#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise real SwiftPM product transport at two checkout paths (macOS/Xcode).

Run under the host's shared heavy-run lock. No network or app assets are used.
The tiny package deliberately requires both Bundle.module and #filePath; hiding
the producer prevents a relocated consumer from passing via the original files.
"""
import argparse
import difflib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent

PACKAGE = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"PathFixture", platforms:[.macOS(.v15)], targets:[
    .target(name:"PathValue"),
    .testTarget(name:"PathTests", dependencies:["PathValue"],
                exclude:["source-marker.txt"], resources:[.copy("Resources")])
])
'''
TEST = '''import Foundation
import XCTest
import PathValue
final class PathTests: XCTestCase {
    func testConsumerOwnsResourceAndSourcePaths() throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path + "/"
        let source = URL(fileURLWithPath:#filePath).resolvingSymlinksInPath()
        let resource = try XCTUnwrap(Bundle.module.url(forResource:"payload", withExtension:"txt", subdirectory:"Resources"))
        print("SOURCE_PATH=" + source.path)
        print("RESOURCE_PATH=" + resource.path)
        XCTAssertTrue(source.path.hasPrefix(root), "#filePath must belong to the consumer")
        XCTAssertTrue(resource.resolvingSymlinksInPath().path.hasPrefix(root), "Bundle.module must belong to the consumer")
        XCTAssertEqual(try String(contentsOf:resource, encoding:.utf8), "resource bytes\\n")
        XCTAssertEqual(try String(contentsOf:source.deletingLastPathComponent().appendingPathComponent("source-marker.txt"), encoding:.utf8), "source bytes\\n")
        XCTAssertEqual(PathValue.value, 42)
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location('ci_products', ROOT/'scripts/ci-products.py')
    products = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(products)

    def run(label, command, cwd, succeeds=True):
        print(label + ': ' + ' '.join(map(str, command)), flush=True)
        result = subprocess.run(list(map(str, command)), cwd=cwd, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        (evidence/(label+'.log')).write_text(result.stdout)
        if (result.returncode == 0) != succeeds:
            raise RuntimeError(f'{label}: unexpected exit {result.returncode}; see {evidence/(label+".log")}')
        return result.stdout

    with tempfile.TemporaryDirectory(prefix='cassini-product-paths-') as temporary:
        folder = Path(temporary).resolve()
        producer, consumer = folder/'producer', folder/'consumer'
        producer.mkdir()
        for name in products.PINS + ['scripts/ci-products.py']:
            destination = producer/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, destination)
        (producer/'Package.swift').write_text(PACKAGE)
        for name, contents in {
            'Sources/PathValue/PathValue.swift': 'public let value = 42\n',
            'Tests/PathTests/PathTests.swift': TEST,
            'Tests/PathTests/source-marker.txt': 'source bytes\n',
            'Tests/PathTests/Resources/payload.txt': 'resource bytes\n',
            '.gitignore': '.build/\n',
        }.items():
            path = producer/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        run('init', ['git', 'init', '-q'], producer)
        run('add', ['git', 'add', '.'], producer)
        run('commit', ['git', '-c', 'user.name=CI path fixture', '-c', 'user.email=ci-path@example.invalid',
                       'commit', '-qm', 'Identical producer and consumer source'], producer)
        run('clone', ['git', 'clone', '--local', '--quiet', producer, consumer], folder)
        run('producer-build', ['swift', 'build', '--build-tests', '--jobs', '4'], producer)
        output = run('producer-test', ['swift', 'test', '--skip-build'], producer)
        assert 'testConsumerOwnsResourceAndSourcePaths' in output and 'Executed 1 test' in output
        artifact = folder/'artifact'
        cli = [sys.executable, 'scripts/ci-products.py']
        run('pack', cli+['pack', 'swiftpm', artifact], producer)
        metadata = json.loads((artifact/'swiftpm.json').read_text())
        assert metadata['workspace'] == str(producer)
        (evidence/'producer-metadata.json').write_text(json.dumps(metadata, indent=2)+'\n')
        accessors = list((producer/'.build').rglob('resource_bundle_accessor.swift'))
        assert accessors and any(str(producer) in p.read_text() for p in accessors)
        (evidence/'resource-accessor.swift').write_text(accessors[0].read_text())

        # No live producer path remains to mask a broken relocation.
        hidden = folder/'producer-unavailable'
        producer.rename(hidden)
        try:
            output = run('foreign-unpack', cli+['unpack', 'swiftpm', artifact], consumer, succeeds=False)
            assert 'WorkspaceMismatch' in output and not (consumer/'.build').exists()

            # Mutation: allow the verified but path-incompatible objects through.
            script = consumer/'scripts/ci-products.py'
            original = script.read_text()
            guard = "if workspace != expected['workspace']:"
            assert original.count(guard) == 1
            try:
                mutated = original.replace(guard, 'if False: # diagnostic mutation')
                (evidence/'workspace-guard.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True), mutated.splitlines(keepends=True), fromfile='a/scripts/ci-products.py', tofile='b/scripts/ci-products.py')))
                script.write_text(mutated)
                run('mutation-restore', cli+['restore', 'swiftpm', artifact], consumer)
                output = run('mutation-test', ['swift', 'test', '--skip-build'], consumer, succeeds=False)
                assert 'could not load resource bundle' in output or 'unable to find bundle' in output or '#filePath must belong to the consumer' in output
            finally:
                script.write_text(original)
                if (consumer/'.build').exists():
                    shutil.rmtree(consumer/'.build')

            output = run('consumer-restore', cli+['restore', 'swiftpm', artifact], consumer)
            assert 'building test products in this checkout' in output
            output = run('consumer-test', ['swift', 'test', '--skip-build'], consumer)
            assert 'SOURCE_PATH='+str(consumer) in output and 'RESOURCE_PATH='+str(consumer) in output
            assert not producer.exists()
        finally:
            hidden.rename(producer)

        # Same-path products still restore and execute, without a rebuild.
        shutil.rmtree(producer/'.build')
        output = run('same-path-restore', cli+['restore', 'swiftpm', artifact], producer)
        assert 'Restored verified swiftpm' in output and 'building test products' not in output
        output = run('same-path-test', ['swift', 'test', '--skip-build'], producer)
        assert 'testConsumerOwnsResourceAndSourcePaths' in output and 'Executed 1 test' in output
        result = dict(producer=str(producer), consumer=str(consumer),
                      commit=metadata['commit'], xcode=metadata['xcode'], arch=metadata['arch'],
                      mutation='foreign objects fail with producer unavailable',
                      restored='consumer-local build passes Bundle.module and #filePath',
                      samePath='verified artifact restored and tests passed without rebuilding')
        (evidence/'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
