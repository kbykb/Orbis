# Orbis fork update — November 19, 2026

This is a fork of [WGooold/Orbis](https://github.com/WGooold/Orbis), distributed under the upstream MIT license. The changes below are maintained in [kbykb/Orbis](https://github.com/kbykb/Orbis).

## Changes

- iPhone conversations use the full display in landscape, including the expanded foldable layout. The session directory opens as a dismissible drawer from the conversation header.
- Added `/orbis-detach` to the Claude Code command menu. It removes a session from Orbis while its native Claude Code process keeps running. The removal survives Host restarts and plugin reconnects.
- Detached sessions keep their saved history. Reopening one reconnects its running native process. If that process is unavailable, Orbis reports it and leaves the session detached; it does not start a replacement process automatically.
- Permission prompts and questions for detached sessions stay with the native client. `/quit` retains its existing process termination behavior.

## iOS package

- Version: `0.1.3`, build `2026111901`.
- Asset: `Orbis-20261119-ios-unsigned.ipa`.
- This package is unsigned and intended for signing with the user's sideloading tool. The app and both extensions require signing.
- Validation passed: Host unit and encrypted-device integration tests, TypeScript checks, 11 layout geometry tests, and a real iPhone simulator flow covering landscape width, drawer controls, rotation, draft input, and navigation. The Release package and app-local dependencies were checked.
- Physical iPhone installation and expanded foldable display verification are pending.

The detach command is supplied by the updated Host and works with existing mobile clients. The full-width iPhone layout requires this iOS build.
