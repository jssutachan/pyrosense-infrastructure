#!/usr/bin/env bash
# stdin -> stdout, with AWS account ids and email addresses replaced.
#
# A second line of defence for text that reaches a public workflow log
# (Terraform errors, init output): the credentials action already masks the
# account id, and sensitive variables are already redacted by Terraform.
# This catches what neither knows about.
set -euo pipefail
sed -E \
  -e 's/[0-9]{12}/<ACCOUNT_ID>/g' \
  -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<EMAIL>/g'
