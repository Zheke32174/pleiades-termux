# Third-Party Notices

The supported Pleiades Termux Edge runtime is dependency-light and uses Python's standard library plus shell tools supplied by Termux. Pleiades-owned source in this repository is MIT licensed.

## Termux and Android

Termux, Android, the device operating system, package manager, shell, Python distribution, Git client, and shared-storage integration are not bundled in this repository. Their licenses, privacy behavior, platform policies, update channels, and security support apply independently.

This repository does not distribute an APK or claim to be an Android application package.

## Python

The edge runtime requires Python 3 and currently uses the standard library. Python itself is supplied by the operator's Termux environment and remains governed by its own license and notices.

## GitHub Actions

Repository workflows use GitHub Actions such as `actions/checkout` and `actions/upload-artifact`. Their source, licenses, and hosted-execution terms apply independently. Workflow use does not make those actions part of the MIT-licensed runtime source.

## Historical material

Files under `scripts/` and retired top-level helpers preserve earlier experiments and copied integration ideas. They are not installed or supported by the current edge bootstrap.

Before extracting any mechanism from historical material, review its exact provenance, license, dependencies, network behavior, data access, and authority assumptions. A Termux shebang does not establish that a script is safe or licensed for redistribution.

## Downstream packaging

The versioned source archive contains repository source only. It does not contain:

- a Termux or Android package;
- Python itself;
- credentials or runtime state;
- an event queue or export;
- a server/container image;
- third-party research tools.

A downstream Android package, Termux package, bundled Python runtime, or integrated transport can create additional license, notice, privacy, source-availability, trademark, and platform-policy obligations. Review the actual downstream artifact rather than relying on this notice as a legal conclusion.
