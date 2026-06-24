# OKDisk MVP Reference Implementation Design

This directory defines the MVP reference design for OKDisk: a native macOS, application-level backup system for personal folders.

## Design specification

The complete design spec is in a single file:

- [**Design Specification**](./design-spec.md) — architecture, storage, metadata, backup/restore flows, verification, multi-destination log coordination, reliability principles, and acceptance criteria.

## Implementation and testing

Implementation plans and testing strategy live in separate documents:

- [Implementation Plan](./implementation-plan.md) — phased working order and acceptance criteria.
- [Core + Engine Plan](./implementation-plan-core-service.md) — core engine, app host, XPC, storage, restore, verification.
- [CLI Plan](./implementation-plan-cli.md) — `okdiskctl` commands and test harness support.
- [GUI Plan](./implementation-plan-gui.md) — menu bar app and management windows.
- [Testing Strategy](./testing-strategy.md) — unit, integration, e2e, crash/corruption, and UI tests.
