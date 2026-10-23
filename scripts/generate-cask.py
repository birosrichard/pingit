#!/usr/bin/env python3
"""Generate a Homebrew cask from the final release ZIP, including its real checksum."""
import hashlib
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def cask(archive):
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('pingit.app/Contents/Info.plist'))
    version = info['CFBundleShortVersionString']
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Expected a stable major.minor.patch app version')
    if info['CFBundleIdentifier'] != 'dev.biros.pingit':
        raise ValueError('Unexpected bundle identifier')
    if info['LSMinimumSystemVersion'] != '14.0':
        raise ValueError('Update the cask minimum macOS version before releasing')
    if archive.name != f'pingit-{version}.zip':
        raise ValueError('ZIP filename must match the bundled app version')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    return f'''cask "pingit" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/birosrichard/pingit/releases/download/v#{{version}}/pingit-#{{version}}.zip"
  name "pingit"
  desc "GitHub pull requests and review requests in your menu bar"
  homepage "https://github.com/birosrichard/pingit"

  depends_on macos: ">= :sonoma"

  app "pingit.app"
end
'''


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: generate-cask.py path/to/pingit-VERSION.zip')
    print(cask(Path(sys.argv[1])), end='')
