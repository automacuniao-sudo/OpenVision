#!/usr/bin/env python3
"""Fail CI if a built personal-developer IPA contains partial Meta attestation config."""
import argparse
import plistlib
import re
import sys


def validate(plist):
    config = plist.get('MWDAT')
    if not isinstance(config, dict):
        raise ValueError('MWDAT dictionary is missing')
    for key in ('MetaAppID', 'ClientToken', 'TeamID'):
        if config.get(key) != '':
            # Report the key only: never disclose a credential in CI logs.
            raise ValueError(f'MWDAT.{key} must be an explicitly empty string for this unsigned developer build')
    callback = config.get('AppLinkURLScheme', '')
    if not isinstance(callback, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9+.-]*://', callback):
        raise ValueError('MWDAT.AppLinkURLScheme must be a resolved callback scheme ending in ://')
    schemes = [scheme for entry in plist.get('CFBundleURLTypes', [])
               for scheme in entry.get('CFBundleURLSchemes', [])]
    if callback[:-3] not in schemes:
        raise ValueError('MWDAT.AppLinkURLScheme does not match CFBundleURLSchemes')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('plist', help='Built JARVIS.app/Info.plist (XML or binary)')
    args = parser.parse_args()
    try:
        with open(args.plist, 'rb') as source:
            validate(plistlib.load(source))
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException) as error:
        print(f'Meta developer configuration validation failed: {error}', file=sys.stderr)
        return 1
    print('Meta developer configuration validated: empty attestation credentials and matching callback')
    return 0


if __name__ == '__main__':
    sys.exit(main())
