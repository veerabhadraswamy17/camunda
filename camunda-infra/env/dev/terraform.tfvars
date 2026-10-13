environment         = "dev"
expected_account_id = "" # TODO: confirm this account is dev

# Names without .fifo (the module adds the suffix)
queue_name = "camunda-orchestrator-replay-queue"
dlq_name   = "camunda-orchestrator-replay-dlq"

sns_topic_arn = ""

# TODO: confirm from an existing subscription's filter policy on the topic
filter_policy_scope = "MessageAttributes" # or "MessageBody"
section_key         = "section"
action_key          = "action"

section_names = [
  # TODO: replace with the 14 real section names (exact, case-sensitive)
  "SECTION_01", "SECTION_02", "SECTION_03", "SECTION_04", "SECTION_05", "SECTION_06", "SECTION_07",
  "SECTION_08", "SECTION_09", "SECTION_10", "SECTION_11", "SECTION_12", "SECTION_13", "SECTION_14",
]

# TODO: team ops-channel SNS topic
ops_alarm_topic_arn = ""
