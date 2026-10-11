output "queue_urls" {
  value = { for k, m in module.sqs : k => m.queue_url }
}

output "dlq_urls" {
  value = { for k, m in module.sqs : k => m.dlq_url }
}

output "consumer_policies" {
  description = "Attach these to the consuming task roles (or feed them into your Service Catalog product)."
  value       = { for k, m in module.sqs : k => m.consumer_policy_json }
}
