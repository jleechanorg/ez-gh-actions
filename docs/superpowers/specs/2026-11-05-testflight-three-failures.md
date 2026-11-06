# TestFlight three-failure SMS escalation
Date: 2026-11-05
Status: implementation specification for existing PR #215

## 1. Goal
Send one SMS after three distinct consecutive completed automatic TestFlight push builds fail or time out; a later successful automatic build resets and rearms the escalation.

## 2. Eligible outcomes
Read the existing ios-testflight.yml workflow run endpoint. Count only event=push, status=completed, and failure conclusions. Treat success as reset; ignore pending runs, workflow_dispatch, cancellation, skipped, neutral, TEST, BLIND, and RUN_STUCK events. Same run attempts have separate identities.

## 3. Ordering and late completion
Order results by (run_number, run_attempt). Persist at most the latest three distinct failures after the latest successful push outcome. Merge late failures while newer success has not superseded them; a newer success anchors the reset so later-arriving older failures cannot reopen the streak. Polling the same attempt is idempotent.

## 4. State and delivery
Extend the monitor's existing JSON state file, preserving existing keys. Log the threshold event as SMS_FAILURE_STREAK, severity ERROR, with numeric failure_streak, repo, workflow, run ID, attempt, GitHub URL, and SHA. The existing run-failure/stuck/blind policy remains Slack-only; the separate policy matches this status, numeric failure_streak>=3, exact repo, and workflow, and routes only to the existing SMS channel. No app SMS sender or service is added.

## 5. Policy and dry-run
--ensure-gcp-policy idempotently ensures both policies. --ensure-gcp-policy --dry-run prints both exact policy JSON documents and makes no GCP or state writes. --dry-run uses a disposable state snapshot so reads and calculations cannot truncate persistent state.

## 6. Acceptance evidence
Offline GH/GCloud fixtures cover first/second/third failure, repeated polls, fourth failure without repeat SMS, success reset/rearm, cancellation/skip/manual/test exclusions, attempts, late failure before/after success, and API-error state preservation. Existing monitor and installer tests plus shell syntax, ShellCheck (when installed), and repo-mandated Cargo tests validate the bounded deterministic behavior. No live GCP write or message send is part of this implementation proof.

## 7. Known scope and limits
The workflow-list API exposes event but not workflow_dispatch inputs; all manual dispatches are therefore excluded, including any manual upload. This specification claims automatic push-build coverage only. A monitor outage or more than 100 unseen runs between polls can delay or lose observations; no cross-repository metadata or sender is introduced.
