# Architecture Checkpoint Review Package

Date: 2026-03-06

## Purpose

This package is for an external architecture review of the current clean-shell migration in Capacitor.

The core question is:

> Is the migration materially succeeding without drift, bypasses, or false confidence, and is the next recommended work really the highest-leverage work?

## Current State

Capacitor started as a broad SwiftUI `AppState` shell around a strong Rust runtime core.
The current migration has already moved substantial behavior behind shell-owned seams:

- `projects`:
  catalog reads, list policy, selection, mutation/import flows, and project feature actions
- `setup`:
  startup readiness, diagnostics, test/repair actions, step orchestration, and onboarding workflow ownership
- `runtime`:
  observation transport, health transport, and automation lifecycle ownership

The latest checkpoint report is included and should be treated as the primary summary artifact:

- `files/Users/petepetrash/Code/capacitor/docs/audit/ARCHITECTURE_CHECKPOINT_2026-03-06.md`

## What To Review

Focus on:

1. whether the migration is actually reducing architectural risk instead of merely moving names around
2. whether the current shell boundaries are real and self-defending enough
3. whether the remaining `AppState` responsibilities are correctly identified
4. whether the next proposed slice is the right one

## Suggested Review Order

1. Checkpoint report
2. Clean architecture assessment
3. From-scratch architecture scaffold
4. Current shell composition and key shell owners
5. Ratchet tests

## Included Files

### Audit docs

- checkpoint report
- clean architecture assessment
- from-scratch scaffold

### Swift shell / composition

- `AppShellContainer`
- `AppState`
- `ProjectFeatureCoordinator`
- `RuntimeSupervisor`
- `RuntimeAutomationController`
- `SetupActionState`
- `SetupStartupCoordinator`
- `SetupWorkflowState`
- `SetupRequirementsManager`

### Ratchets / focused tests

- `ArchitectureBoundaryTests`
- `AppShellContainerTests`
- `ProjectFeatureCoordinatorTests`
- `RuntimeSupervisorTests`
- `RuntimeAutomationControllerTests`
- `SetupActionStateTests`
- `SetupStartupCoordinatorTests`
- `SetupWorkflowStateTests`
- `SetupRequirementsManagerTests`

## Reviewer Deliverable

Please return:

- a `GO`, `GO WITH WARNINGS`, or `STOP` judgment
- the 3 highest-risk architecture issues still present
- any signs of drift, dead scaffolding, or false confidence
- whether the proposed next slice is correct
- any missing ratchets or verification steps that should exist before continuing
