# Changelog

All notable changes to this module are documented here. Versions follow [SemVer](https://semver.org/):
MAJOR = breaking input/output or resource-address change, MINOR = new optional feature, PATCH = fix.

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
