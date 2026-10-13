# terraform-aws-sqs

Enterprise-grade Terraform module for Amazon SQS. Secure by default, hard to misuse, and ready to be consumed by many teams through a pinned git tag.

## What you get by default

| Area | Default behaviour |
|---|---|
| Naming | Taken from `queue_name` / `dlq_name` (set per env in tfvars); `.fifo` added automatically; DLQ defaults to `<queue_name>-dlq` |
| Dead-letter queue | On. `maxReceiveCount = 5`, 14-day retention, only the source queue may redrive into it |
| Encryption at rest | SSE-KMS with a new customer-managed key (rotation on, alias `alias/sqs/<name>`) |
| Encryption in transit | Queue policy denies any non-TLS request |
| Access | Explicit producer/consumer ARNs; optional org perimeter (`aws:PrincipalOrgID`) |
| Polling | Long polling (20 s) |
| Monitoring | 3 CloudWatch alarms: oldest-message age, backlog, DLQ not empty |
| Tags | Required tag keys enforced at plan time, plus `application`, `environment`, `managed-by`, `module` |

Unencrypted queues are not possible with this module.

## Usage

```hcl
module "connector_jobs" {
  source = "git::https://<your-git>/terraform-aws-sqs.git?ref=v1.0.0"

  application = "camunda"
  environment = "dev"
  queue_name  = "camunda-dev-connector-jobs"

  visibility_timeout_seconds = 120
  alarm_actions              = [aws_sns_topic.alerts.arn]

  tags = {
    owner               = "platform-team"
    cost-centre         = "CC1234"
    data-classification = "internal"
  }
}

# Grant the ECS task role access (includes kms:Decrypt for the queue key)
resource "aws_iam_role_policy" "consume" {
  role   = aws_iam_role.camunda_task.id
  policy = module.connector_jobs.consumer_policy_json
}
```

More in [`examples/`](examples):

| Example | Shows |
|---|---|
| `basic` | Standard queue + attaching the consumer policy to an ECS task role |
| `fifo-high-throughput` | FIFO, high-throughput mode, bring-your-own KMS key, org perimeter |
| `sns-fanout` | One SNS topic fanned out to three queues, with filter policies |
| `multi-queue-root` | Root module with `for_each` over a queue map and `env/<env>/` backend + tfvars |

## Files

| File | Contents |
|---|---|
| `main.tf` | Main queue, DLQ, redrive policy, redrive-allow policy, preconditions |
| `kms.tf` | Optional CMK, key policy (IAM delegation, cross-account principals, SNS, EventBridge), alias |
| `policy.tf` | Queue resource policies (main + DLQ), producer/consumer identity policy documents |
| `sns.tf` | SNS → SQS subscriptions |
| `alarms.tf` | CloudWatch alarms |
| `locals.tf` | Name suffixing, encryption and tag logic |
| `variables.tf` / `outputs.tf` / `versions.tf` | Interface and version constraints |
| `tests/` | `terraform test` suite using a mocked AWS provider |

## Inputs (summary)

**Required:** `queue_name`, `application`, `environment` (`dev`, `sit`, `uat`, `preprod`, `prod`; both used for tags), `tags` (must include `required_tag_keys`).

| Group | Inputs |
|---|---|
| Queue | `fifo_queue`, `content_based_deduplication`, `high_throughput_fifo`, `visibility_timeout_seconds` (60), `message_retention_seconds` (4 d), `delay_seconds`, `max_message_size`, `receive_wait_time_seconds` (20) |
| DLQ | `create_dlq` (true), `dlq_max_receive_count` (5), `dlq_message_retention_seconds` (14 d) |
| Encryption | `encryption_type` (`kms` / `sqs`), `kms_key_arn`, `kms_data_key_reuse_period_seconds`, `kms_key_deletion_window_in_days` |
| Access | `producer_arns`, `consumer_arns`, `organization_id`, `eventbridge_rule_arns`, `source_policy_documents` |
| SNS | `sns_subscriptions` (map of `topic_arn`, `raw_message_delivery`, `filter_policy`, `filter_policy_scope`, `create_subscription`) |
| Alarms | `create_alarms`, `alarm_actions`, `ok_actions`, `alarm_period_seconds`, `alarm_evaluation_periods`, `oldest_message_age_threshold_seconds`, `visible_messages_threshold`, `dlq_messages_threshold` |
| Naming / tags | `queue_name`, `dlq_name`, `required_tag_keys` |

Every input has a description, type and validation in `variables.tf`. Generate the full table with `terraform-docs markdown table . > INPUTS.md` (or let the pre-commit hook inject it).

## Outputs

`queue_name`, `queue_arn`, `queue_url`, `dlq_name`, `dlq_arn`, `dlq_url`, `kms_key_arn`, `kms_alias_name`, `producer_policy_json`, `consumer_policy_json`, `sns_subscription_arns`, `alarm_arns`.

## Guard-rails enforced at plan time

- Queue and DLQ names: allowed characters only, no `.fifo` typed by hand, ≤ 80 characters including the suffix.
- All `required_tag_keys` present and non-empty.
- FIFO-only settings rejected on standard queues.
- DLQ retention ≥ main queue retention (for standard queues a message keeps its original enqueue time when moved, so a shorter DLQ retention can delete it immediately).
- A FIFO queue can only subscribe to FIFO SNS topics.

## Design decisions

- **Names come from the caller.** `queue_name`/`dlq_name` are set in tfvars rather than derived from a convention, so names mandated by a story or an existing standard need no workaround. Consistency is enforced by review and the format validation.
- **One queue per module call.** Create many with `for_each` in the root module. Keeps state addresses stable and the module simple.
- **No IAM roles created.** The module outputs policy JSON; the workload owns its role. This fits setups where roles/task definitions come from another pipeline (e.g. a Service Catalog product).
- **No provider block.** Region, credentials and `default_tags` belong to the root module.
- **Separate redrive-allow resource.** Avoids a dependency cycle between the queue and its DLQ.
- **SNS subscription waits for the queue policy**, so early messages are not silently dropped.

## Gotchas

- **External KMS key:** if you pass `kms_key_arn`, that key's policy must allow your producers/consumers and `sns.amazonaws.com` / `events.amazonaws.com` (`kms:GenerateDataKey*`, `kms:Decrypt`). A missing statement makes SNS delivery fail silently. AWS-managed `alias/aws/sqs` cannot be used with SNS/EventBridge sources for this reason.
- **Cross-account SNS topics:** the queue owner can create the subscription from its own account if the topic policy allows `sns:Subscribe` for that account (it is then confirmed automatically). If the topic owner prefers to create it, set `create_subscription = false`; the queue/KMS policies here still allow delivery.
- **Visibility timeout** must exceed the consumer's processing time, otherwise messages are processed twice and can end up in the DLQ.
- **`prevent_destroy`** cannot be driven by a variable. For production, either fork a `lifecycle { prevent_destroy = true }` into the module or protect state with SCPs / pipeline approval.
- **`organization_id` perimeter** denies any principal outside the org, including support tooling in external accounts. Add exceptions through `source_policy_documents` if needed.

## Development

```bash
terraform fmt -recursive
terraform init -backend=false && terraform validate
terraform test            # mocked provider, no AWS credentials needed
tflint --init && tflint
checkov -d .              # or: trivy config .
pre-commit install        # runs all of the above on commit
```

## Versioning

SemVer git tags (`v1.0.0`). Consumers must pin `?ref=vX.Y.Z`. Breaking changes (renamed inputs/outputs, changed resource addresses) bump MAJOR and are listed in `CHANGELOG.md` with migration notes (`moved` blocks where possible).

## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.7.0 |
| hashicorp/aws | >= 5.40.0, < 7.0.0 |
