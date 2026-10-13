locals {
  tags = {
    team    = var.team
    project = var.project
  }

  # section ∈ {14 names}  AND  action ∈ {COMPLETED}
  # (keys are ANDed, values in one array are ORed)
  filter_policy = jsonencode({
    (var.section_key) = var.section_names
    (var.action_key)  = var.action_values
  })
}

# SNS caps filter-policy value combinations at 150 (product of values per key).
check "filter_policy_size" {
  assert {
    condition     = length(var.section_names) * length(var.action_values) <= 150
    error_message = "section_names x action_values exceeds the SNS filter policy limit of 150 combinations; the subscription will be rejected."
  }
}
