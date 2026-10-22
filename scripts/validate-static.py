#!/usr/bin/env python3
"""Portable repository checks. This does not compile Swift or run macOS tests."""
import json
import plistlib
import re
import subprocess
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def parse_project(text):
    # Read this project's OpenStep property list without a platform dependency.
    tokens = re.findall(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+', text)
    tokens = iter(t for t in tokens if not t.isspace() and not t.startswith(('//', '/*')))
    token = next(tokens, None)

    def take(expected=None):
        nonlocal token
        value = token
        check(value is not None and (expected is None or value == expected), f"project token {value!r}; expected {expected!r}")
        token = next(tokens, None)
        return value

    def value():
        if token == '{':
            take('{')
            result = {}
            while token != '}':
                key = take()
                check(key not in result, f"duplicate project key {key}")
                take('=')
                result[key] = value()
                take(';')
            take('}')
            return result
        if token == '(':
            take('(')
            result = []
            while token != ')':
                result.append(value())
                if token != ')':
                    take(',')
            take(')')
            return result
        scalar = take()
        return json.loads(scalar) if scalar.startswith('"') else scalar

    result = value()
    check(token is None, "unexpected trailing project tokens")
    return result


def main():
    project = parse_project((ROOT / 'pingit.xcodeproj/project.pbxproj').read_text())
    objects = project['objects']
    paths = {}

    def references(value):
        if isinstance(value, dict):
            for item in value.values():
                references(item)
        elif isinstance(value, list):
            for item in value:
                references(item)
        elif re.fullmatch(r'[A-F0-9]{24}', value):
            check(value in objects, f"missing project object {value}")

    references(project)

    def visit(identifier, parent):
        item = objects[identifier]
        tree = item.get('sourceTree', '<group>')
        if tree == 'BUILT_PRODUCTS_DIR':
            return
        check(tree == '<group>', f"unhandled source tree {tree}")
        path = parent / item.get('path', '')
        paths[identifier] = path
        for child in item.get('children', []):
            visit(child, path)
        if item['isa'] == 'PBXFileReference':
            check(path.exists(), f"missing referenced file {path.relative_to(ROOT)}")

    visit(objects[project['rootObject']]['mainGroup'], ROOT)
    targets = {}
    for item in objects.values():
        if item['isa'] != 'PBXNativeTarget':
            continue
        compiled = []
        for phase_id in item['buildPhases']:
            phase = objects[phase_id]
            files = phase.get('files', [])
            check(len(files) == len(set(files)), f"duplicate phase entry in {item['name']}")
            for file_id in files:
                ref = objects[file_id]['fileRef']
                check(ref in paths, f"ungrouped build reference {ref}")
                if phase['isa'] == 'PBXSourcesBuildPhase':
                    compiled.append(paths[ref])
        check(len(compiled) == len(set(compiled)), f"duplicate compiled source in {item['name']}")
        targets[item['name']] = set(compiled)
    check(set((ROOT / 'pingit').rglob('*.swift')) == targets['pingit'], "app Swift source membership mismatch")
    check(set((ROOT / 'pingitTests').glob('*.swift')) <= targets['pingitTests'], "test Swift source membership mismatch")
    notification_files = set((ROOT / 'pingit/Core/Notifications').glob('*.swift'))
    check(notification_files <= targets['pingitTests'], "notification sources missing from test target")
    print('PASS: project syntax, unique objects, references, source paths and target membership')

    for path in (ROOT / 'pingit').rglob('*'):
        if path.suffix in ('.plist', '.entitlements'):
            plistlib.loads(path.read_bytes())
        if path.name == 'Contents.json':
            contents = json.loads(path.read_text())
            for entry in contents.get('images', []):
                if entry.get('filename'):
                    check((path.parent / entry['filename']).is_file(), f"missing asset {entry['filename']}")
    for path in (ROOT / 'pingit.xcodeproj').rglob('*.xcscheme'):
        tree = ElementTree.parse(path)
        for entry in tree.findall('.//BuildableReference'):
            check(entry.attrib['BlueprintIdentifier'] in objects, "invalid scheme target")
    print('PASS: plist/entitlement XML, shared scheme and asset references')

    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    credentials = re.compile(r'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
    for filename in filter(None, files):
        path = ROOT / filename
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except UnicodeError:
            continue
        check(not re.search(r'^(?:<<<<<<< |=======$|>>>>>>> )', text, re.M), f"conflict marker in {filename}")
        check(not credentials.search(text), f"credential-like value in {filename}")
        if path.suffix == '.md':
            for target in re.findall(r'\[[^\]]*\]\(([^\s)]+)\)', text):
                if re.match(r'[a-z]+:|#|/', target):
                    continue
                destination = target.split('#')[0]
                check((path.parent / destination).exists(), f"broken documentation link {filename}: {target}")
    for path in notification_files:
        text = path.read_text()
        check(not re.search(r'@unchecked|nonisolated\(unsafe\)|as!|try!|\w!|os\(Linux\)', text), f"unsafe construct in {path.name}")
    print('PASS: conflict markers, credential patterns, local Markdown links and notification source safety scan')

    config = (ROOT / 'Configuration/App.xcconfig').read_text()
    for setting in ['SWIFT_VERSION = 6.0', 'SWIFT_STRICT_CONCURRENCY = complete', 'SWIFT_TREAT_WARNINGS_AS_ERRORS = YES']:
        check(setting in config, f"required Swift setting missing: {setting}")
    for path in (ROOT / 'scripts').glob('*.sh'):
        subprocess.run(['sh', '-n', str(path)], check=True)
    subprocess.run(['git', 'diff', '--check', 'origin/main'], cwd=ROOT, check=True)
    print('PASS: strict Swift settings, shell syntax and git diff whitespace')
    print('Static checks only. macOS compilation, tests, signing, launch and delivery remain unverified.')


if __name__ == '__main__':
    main()
