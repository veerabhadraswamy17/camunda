# camunda-infra — Camunda orchestrator replay queue

Implements the **MO Replacement – Camunda POC** story: an SQS FIFO queue subscribed to
`mae_apptracking_event_log.fifo`, with a FIFO DLQ and a DLQ alarm to the team ops channel.

```
mae_apptracking_event_log.fifo (SNS FIFO, same account)
   │  subscription: raw delivery, filter = section ∈ {14} AND action = COMPLETED
   ▼
camunda-orchestrator-replay-queue.fifo   visibility 120 s · retention 4 d · KMS
   │  redrive: maxReceiveCount = 3
   ▼
camunda-orchestrator-replay-dlq.fifo ──► CloudWatch alarm (visible > 0) ──► ops SNS topic
```

## Layout

| Path | Purpose |
|---|---|
| `camunda-infra/` | Root module: provider, tags, filter policy, one call to `modules/sqs`, outputs |
| `env/<env>/terraform.tfvars` | Per-environment values (queue/DLQ names, topic ARN, sections, ops topic, account ID) |
| `env/<env>/backend.tfvars` | Your existing state backend config (unchanged) |
| `modules/sqs/` | Reusable enterprise SQS module (v2.0.0) — replaces the old `iam.tf`/`logs.tf`/`sqs.tf`/`version.tf` |

## Deploy

```bash
cd camunda-infra
terraform init  -backend-config=../env/dev/backend.tfvars
terraform plan  -var-file=../env/dev/terraform.tfvars -out=dev.tfplan
terraform apply dev.tfplan
terraform output          # ARNs to paste into the ticket / wiki
```

## Acceptance criteria → implementation

| Criterion | Where |
|---|---|
| FIFO queue `camunda-orchestrator-replay-queue.fifo` in eu-west-2 | `queue_name` in tfvars, `fifo_queue = true` in `sqs.tf`, `var.region` |
| MessageGroupId = applicationId | **Publisher responsibility** (MAE team). SNS FIFO passes it through; nothing to configure here |
| Content-based dedup OR publisher dedup ID | `content_based_deduplication = true` (topic also has it enabled) |
| DLQ `camunda-orchestrator-replay-dlq.fifo`, maxReceiveCount 3 | `dlq_name` in tfvars, `max_receive_count = 3` |
| SNS subscription with raw delivery | `sns_subscriptions.mae_apptracking` |
| Filter: 14 sections AND action COMPLETED | `locals.tf` + `section_names` in tfvars |
| Queue, subscription and DLQ ARNs documented | `terraform output` → fill the table below |
| CloudWatch alarm DLQ depth > 0 → ops channel | module DLQ alarm, `ops_alarm_topic_arn` |
| Visibility ≥ 60 s | validated in `variables.tf` (default 120) |
| Retention 4 days | `message_retention_seconds = 345600` |
| Tags team / project | provider `default_tags` + enforced via `required_tag_keys` |

## Deployed resources (fill after apply)

| Env | Queue ARN | DLQ ARN | Subscription ARN |
|---|---|---|---|
| dev | | | |
| sit | | | |
| prod | | | |

## Before first apply — open items

1. **Filter fields.** Open any existing subscription on the topic (SNS → Topics →
   `mae_apptracking_event_log.fifo` → Subscriptions → pick one → *Subscription filter policy*).
   It shows whether other teams filter on *message attributes* or the *message body* and the exact
   key names. Set `filter_policy_scope`, `section_key`, `action_key` accordingly.
2. **14 section names** in `env/<env>/terraform.tfvars` (exact, case-sensitive).
3. **Ops alarm topic ARN.** If that topic is KMS-encrypted with a CMK, its key policy must allow
   `cloudwatch.amazonaws.com` (`kms:GenerateDataKey*`, `kms:Decrypt`), or the alarm fires silently.
4. **Account IDs** for sit/prod (`expected_account_id`) and their topic ARNs.
5. **Encryption standard.** Default is a module-created CMK; set `encryption_type = "sqs"` or
   `kms_key_arn` if your org mandates otherwise.

## Verify after apply (in scope)

```bash
Q=$(terraform output -raw queue_url)
aws sqs get-queue-attributes --queue-url "$Q" --attribute-names All
aws sns get-subscription-attributes --subscription-arn "$(terraform output -raw subscription_arn)"
aws cloudwatch describe-alarms --alarm-name-prefix sqs-camunda-orchestrator-replay
# Test the alarm notification path without waiting for a real failure:
aws cloudwatch set-alarm-state --alarm-name sqs-camunda-orchestrator-replay-queue-dlq-not-empty \
  --state-value ALARM --state-reason "notification test"
```

End-to-end flow with real events is Sprint 2 (out of scope).

## For the listener (S1-04)

Attach `terraform output -raw consumer_policy_json` to the listener's task role. The listener
receives the **raw** event JSON (no SNS envelope), must delete after success, and must be
idempotent. The ECS tasks reach SQS through the `com.amazonaws.eu-west-2.sqs` interface VPC endpoint.
