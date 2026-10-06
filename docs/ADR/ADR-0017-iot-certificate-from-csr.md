# ADR-0017: Device certificate issued from a CSR inside Terraform; private key never in state

- **Status:** Proposed
- **Date:** 2026-09-24
- **Module:** `modules/iot`

## Context

Standard #13 forbids X.509 private keys in Terraform state or in the
repository: state stores everything in clear text. Standard #5 forbids
clickops. A fully out-of-band certificate (CLI script) satisfies #13 but
leaves the certificate, its activation, and its links to the policy and
Thing outside `.tf`.

There is also an ordering problem. An IoT policy attached to a certificate
cannot be deleted while attached, so `terraform destroy` would depend on a
script having detached it first.

Verified in the AWS provider 6.x (`aws_iot_certificate`):

- With `csr` set, the provider calls `CreateCertificateFromCsr`.
  `private_key` and `public_key` are populated **only when neither a CSR
  nor a certificate is provided**.
- `csr` is not sensitive and forces replacement.
- `certificate_pem` is marked sensitive.
- On delete, the provider sets the certificate `INACTIVE` and then deletes
  it.

## Decision

1. The operator generates the key pair and CSR locally (RSA 2048), in
   `~/.config/pyrosense/certs/<env>/`, outside both repositories, with mode
   600.
2. Terraform receives **only the CSR**. The root reads it with `file()`
   from a path set in the gitignored tfvars. Terraform owns the
   certificate, the Thing, the Thing–principal attachment
   (`EXCLUSIVE_THING`) and the policy attachment.
3. The operator writes the issued (public) certificate to disk from a
   sensitive output.

## Rationale

- **#13 holds.** State contains the CSR and the certificate: public
  material only.
- **#5 holds without exception.** Every AWS object is in `.tf`. The only
  out-of-band step, key generation, is out-of-band by definition: a
  secret generated inside Terraform lands in state.
- **Destroy is correct by construction.** Terraform detaches, deactivates
  and deletes in dependency order. No script has to run first.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| `aws_iot_certificate` without CSR | AWS generates the key and the provider stores `private_key` in state: violates #13. |
| Versioned script in `scripts/` (`create-keys-and-certificate` or `create-certificate-from-csr` + attach calls) | Documented exception to #5, two sources of truth, and a destroy that must run the script's detach first or fail. |
| Commit the CSR to the repository | Not secret, but it pins one key pair per repository clone and invites people to treat `certs/` as a normal folder. |

## Consequences

- `terraform plan` needs the CSR file to exist: a fresh machine must run
  the runbook first (fail-fast, intended).
- Every demo cycle reissues a certificate from the same key pair. Key reuse
  across cycles is accepted for the demo.
- The certificate PEM leaves Terraform through a sensitive output
  (`terraform output -raw`).

## Revision trigger

- Production devices provisioned at scale: move to fleet provisioning or
  JITP, where devices never hand a CSR to an operator.
- A CI pipeline that must plan without an operator's CSR.
- A key compromise, which requires rotation (new key + CSR) and a
  revocation procedure.
