variable "name_prefix" {
  description = "Resource name prefix assembled by the root (resource_prefix-environment), e.g. pyrosense-demo. Names the Thing (= MQTT client ID), the IoT policy, the IAM roles, the topic rule and the error log group."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.name_prefix))
    error_message = "name_prefix must be 1-64 characters of lowercase letters, digits and hyphens."
  }
}

# The two topic segments below are validated to the same 64-character,
# lowercase-alphanumeric-hyphen alphabet as name_prefix. That alphabet
# excludes "$" (topics starting with $ are reserved for AWS IoT Core), the
# MQTT wildcards "+" and "#", and "/" (each segment is exactly one topic
# level). With both capped at 64 characters, the longest telemetry topic is
# 64 + 1 + 64 + len("/telemetry/") + 12 (device_id) = 152 bytes and it has
# 3 slashes, which stays inside the service limits (256 bytes, 7 slashes)
# for every value these validations accept. No precondition is needed.

variable "topic_base" {
  description = "First level of the MQTT topic tree: {base} in {base}/{env}/telemetry/{device_id}. Contract with the simulator (PYROSENSE_TOPIC_BASE); exported through the simulator_env output."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.topic_base))
    error_message = "topic_base must be a single topic level of 1-64 lowercase letters, digits or hyphens (no $, +, # or /)."
  }
}

variable "environment" {
  description = "Deployment environment; becomes the {env} level of the MQTT topic tree. Contract with the simulator (PYROSENSE_ENV); exported through the simulator_env output."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{1,64}$", var.environment))
    error_message = "environment must be a single topic level of 1-64 lowercase letters, digits or hyphens (no $, +, # or /)."
  }
}

variable "queue_arn" {
  description = "ARN of the ingest queue (modules/messaging output queue_arn). Scopes sqs:SendMessage in the forwarding role."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z-]+:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,80}$", var.queue_arn))
    error_message = "queue_arn must be a standard SQS queue ARN (FIFO queues are not supported by the IoT SQS rule action)."
  }
}

variable "queue_url" {
  description = "URL of the ingest queue (modules/messaging output queue_url). The IoT SQS rule action addresses the queue by URL, not ARN."
  type        = string

  validation {
    condition     = can(regex("^https://", var.queue_url)) && !endswith(var.queue_url, ".fifo")
    error_message = "queue_url must be an https:// SQS URL of a standard (non-FIFO) queue."
  }
}

variable "kms_key_arn" {
  description = "ARN of the pipeline CMK (modules/security output kms_key_arn). The forwarding role needs it for the encrypted queue; the error log group is encrypted with it."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z-]+:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (key/<uuid>), not an alias."
  }
}

variable "fleet_client_csr_pem" {
  description = "PEM certificate signing request for the fleet client. The matching private key is generated on the operator's machine and never reaches Terraform (ADR-0017). Differs per environment: each environment gets its own key pair."
  type        = string

  validation {
    # CreateCertificateFromCsr accepts at most 4096 characters.
    condition = (
      can(regex("^-----BEGIN (NEW )?CERTIFICATE REQUEST-----", trimspace(var.fleet_client_csr_pem)))
      && length(var.fleet_client_csr_pem) <= 4096
    )
    error_message = "fleet_client_csr_pem must be a PEM CSR (-----BEGIN CERTIFICATE REQUEST-----) of at most 4096 characters. Never pass a private key here."
  }
}
