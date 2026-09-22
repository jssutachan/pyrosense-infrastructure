output "kms_key_arn" {
  description = "ARN of the customer-managed pipeline key. This is the value every other module consumes."
  value       = aws_kms_key.pipeline.arn
}

output "kms_key_id" {
  description = "ID of the customer-managed pipeline key."
  value       = aws_kms_key.pipeline.key_id
}

output "kms_alias_name" {
  description = "Alias of the pipeline key, e.g. alias/pyrosense-demo-pipeline."
  value       = aws_kms_alias.pipeline.name
}

output "kms_alias_arn" {
  description = "ARN of the pipeline key alias, for resources that accept an alias ARN."
  value       = aws_kms_alias.pipeline.arn
}
