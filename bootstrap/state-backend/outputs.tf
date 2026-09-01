output "state_bucket_name" {
  description = "Bucket to reference from config/backend.hcl."
  value       = aws_s3_bucket.state.bucket
}
