# Changelog

All notable changes to this module are documented here. Versions follow [SemVer](https://semver.org/):
MAJOR = breaking input/output or resource-address change, MINOR = new optional feature, PATCH = fix.

## [2.0.0] - 2026-10-13
### Changed (breaking)
- Queue names are now passed in directly: new required `queue_name` and optional `dlq_name` (default `<queue_name>-dlq`).
  Removed `name` and `name_override`; the `<application>-<environment>-<name>` convention is no longer built in.
  Migration: set `queue_name = "<application>-<environment>-<name>"` to keep existing names (no resource replacement).
- `application` and `environment` are now used only for tags.
### Added
- `queue_settings` output.
### Fixed
- README/variable docs: cross-account subscriptions can be created by the queue owner when the topic policy allows it.

## [1.0.0] - 2026-10-11
### Added
- Standard and FIFO queues (incl. high-throughput FIFO) with enforced naming convention.
- Dead-letter queue by default, redrive allow-policy restricted to the source queue.
- SSE-KMS with module-created rotating CMK (or bring your own key); SSE-SQS option.
- Queue policies: TLS-only, optional organisation perimeter, producers/consumers, SNS and EventBridge sources.
- SNS fan-out subscriptions with raw delivery and filter policies.
- CloudWatch alarms: oldest-message age, backlog, DLQ not empty.
- Producer/consumer IAM policy JSON outputs.
- Required-tag enforcement, examples, mocked `terraform test` suite.
