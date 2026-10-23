# ADR-0023: Pipeline identity through OIDC, two roles and a workload boundary

- **Status:** Proposed
- **Date:** 2026-10-23
- **Stage:** CI/CD, sub-stage C2 (pipeline identity)

## Context

From C3 on, GitHub Actions must call AWS: `terraform plan` in pull requests
(C3), then apply and destroy of the ephemeral `demo` environment behind a
human approval (C4). Until now only the operator has called AWS, from the
workstation, as an IAM user with administrator rights.

Facts that shaped the decision:

- **The repository is public.** Workflow logs are readable by any signed-in
  GitHub user. Anything in a `with:` input that is not a secret is printed in
  the log.
- **What Terraform does in AWS was measured, not guessed.** CloudTrail Event
  History for 2026-10-14..20 (three full deploy/destroy cycles) shows 116
  distinct API calls across 12 services made with a Terraform user agent. The
  writes include `iam:CreateRole`, `iam:PutRolePolicy`, `lambda:CreateFunction`
  and `iot:CreateTopicRule`: the configuration creates three IAM roles (two
  IoT rule roles, one Lambda execution role) and writes their policies.
- **That makes privilege escalation the central risk.** An identity that can
  write an inline policy on a role, and pass that role to a Lambda function it
  creates, can run code with any permission it writes. Restricting role
  *names* does not help: `pyrosense-demo-anything` is a valid name.
- **CloudTrail does not list everything.** API names differ from IAM action
  names (`PutBucketEncryption` is authorised by `s3:PutEncryptionConfiguration`);
  implicit permissions (`iam:PassRole`, the `Tag*` actions behind a create with
  tags, `kms:CreateGrant` for Lambda and DynamoDB) never appear as events; and
  data events (`sqs:GetQueueAttributes`, S3 object calls) are not in Event
  History. IAM Access Analyzer policy generation needs a trail, and the account
  has none.
- **GitHub changed the OIDC subject in 2026.** Repositories created on or
  after 2026-07-15 emit an immutable `sub` that carries the numeric owner and
  repository ids (`repo:owner@id/repo@id:...`); older repositories keep the
  name-only format unless they opt in. A trust policy that matches only names
  can be satisfied by whoever registers the name after a rename or deletion.
- **AWS STS (2026-01) accepts more GitHub claims as trust conditions**, among
  them `repository_id`, `repository_owner_id`, `actor_id` and `environment`.
- **The project's state bucket is the most sensitive object the pipeline
  touches**: the state of the main configuration holds every resource's
  attributes, alert recipients included.
- **The `demo` environment is destroyed after every cycle (ADR-0002)**, while
  the pipeline's identity must outlive every cycle.

## Decision

**D1. OIDC federation, no stored keys.** GitHub Actions obtains temporary
credentials with `sts:AssumeRoleWithWebIdentity`, using GitHub's OIDC token
and an IAM OIDC identity provider for `token.actions.githubusercontent.com`
with audience `sts.amazonaws.com`. No access key exists for the pipeline. The
official `aws-actions/configure-aws-credentials` action is used, pinned to a
commit SHA, with `mask-aws-account-id: true` (it is off by default).

**D2. The identity lives in its own long-lived stack, applied by the
operator.** `bootstrap/ci-identity` holds the identity provider, both roles,
their policies and the workload boundary. It keeps its state in the existing
state bucket under its own key (`bootstrap/ci-identity/terraform.tfstate`),
which neither pipeline role can read. The pipeline never applies this stack:
an identity that could edit its own permissions would have no ceiling.

**D3. Two roles, because reading and changing are different risks.**

| Role | Assumable from | May do |
|---|---|---|
| `pyrosense-ci-plan` | pull requests (`sub` = `...:pull_request`) | read project configuration; read the main state; take its lock |
| `pyrosense-ci-apply-demo` | the GitHub environment `demo` (`sub` = `...:environment:demo`), which requires the maintainer's approval | the above, plus write the state and create, change and delete resources named `pyrosense-demo-*` |

A job that names an environment gets an environment `sub`, so the apply job
can never assume the plan role and a pull request can never assume the apply
role.

**D4. Every trust condition is an exact match on immutable values.** Both
trust policies require, with `StringEquals` only: `aud` = `sts.amazonaws.com`;
the exact `sub` in the immutable format; `repository_id`;
`repository_owner_id`; and `actor_id` in the list of maintainers (one today).
No `StringLike`, no wildcard in `sub`. A run started by anyone else, a fork
pull request included, gets no AWS credentials, independently of GitHub's
handling of `id-token` for forks.

**D5. A permissions boundary closes the escalation path.** The managed policy
`pyrosense-workload-boundary` caps every role the pipeline creates at the data
path of the project (send/receive on project queues, write project log
streams, put items, put objects, publish alerts, use KMS keys of the account).
The apply role may create, edit or delete roles named `pyrosense-demo-*`
**only if** they carry that exact boundary (`iam:PermissionsBoundary`), may
pass them only to Lambda and IoT (`iam:PassedToService`), and is explicitly
denied removing or replacing a boundary and any IAM write on the pipeline's own
roles, policies and identity provider. A role it creates with `"Action": "*"`
gets, at most, the boundary. `modules/iot` and `modules/ingest` set the
boundary on their three roles through a required input; the main
configuration reads the boundary by name, so a plan fails early if the
bootstrap stack is missing.

**D6. Scope is chosen per resource type, tightest available first.**
1. exact object: the state file and its lock file;
2. name prefix `pyrosense-demo-*` (queues, topics, tables, buckets, roles,
   functions, log groups, alarms, IoT things, policies and rules);
3. tags `Project=PyroSense` and `Environment=demo`, checked at creation and on
   every later call, for KMS keys (their ARN is a random id);
4. `"*"`: configuration reads, and the creates that have no resource ARN yet
   (`kms:CreateKey` with the tag condition, `iot:CreateCertificateFromCsr`,
   Lambda event source mappings with a `lambda:FunctionArn` condition).

Reads are an explicit list, not the AWS-managed `ReadOnlyAccess` policy, which
also grants reads of data (S3 objects, DynamoDB items, log events).

**D7. Role ARNs are GitHub secrets.** `AWS_PLAN_ROLE_ARN` is a repository
secret and `AWS_APPLY_ROLE_ARN` a secret of the `demo` environment. They are
not credentials, but they contain the account id, and a non-secret `with:`
input is printed in the public log. An environment secret is not available to
a job until the environment's reviewer approves it.

**D8. The permission set is a measured first version, proven by use.** It was
derived from CloudTrail and completed by hand from the service authorization
reference. The OIDC probe workflow proves the trust and the denials in C2; C3
exercises every read and C4 every write. An `AccessDenied` there is a missing
line, added with its reason, never a wildcard.

## Rationale

- OIDC is the mechanism AWS and GitHub both document for this case, and it
  removes the most common CI incident class: a long-lived key leaked from a
  secret store or a log.
- The boundary is the pattern AWS documents for delegating IAM administration
  (delegated administrator with `iam:PermissionsBoundary` conditions and
  `NoBoundaryPolicyEdit`/`NoBoundaryUserDelete` denies). It is the only option
  that lets the pipeline create the project's roles without being able to
  create an administrator.
- Two roles keep the most frequent job (plan, on every pull request) unable to
  change anything, and put every change behind GitHub's environment approval,
  which happens before the job starts: there is no token to steal until a
  human approves.
- Immutable ids in the trust policy remove a whole failure mode (a renamed or
  deleted repository whose name is taken over) at no cost.

## Alternatives considered

| Alternative | Why not |
|---|---|
| IAM user with access keys stored as GitHub secrets | Long-lived credentials; rotation by hand; one leak in a public log is an incident. Rejected by the stage contract |
| One role for plan and apply | Every pull request would run with write access; a malicious or broken workflow change in a PR could change AWS |
| Apply role with `AdministratorAccess` or `PowerUserAccess` plus `iam:*` | Simple, and common in tutorials, but the pipeline would be an administrator with no ceiling |
| Name-prefix scoping of IAM roles without a boundary | Does not stop escalation: the prefix is free to choose |
| Pre-create the three workload roles in the bootstrap stack and let the pipeline only pass them | No IAM writes at all, the strongest option. Rejected for now: it moves module internals (the roles' policies, which reference per-cycle ARNs such as the queue and the CMK) out of the modules, and breaks ADR-0002's "every module is applied and destroyed whole". Revisit for production |
| The identity inside `bootstrap/state-backend` | That stack keeps local state (debt #53); a second responsibility would raise the cost of losing the file, and it mixes a stack that never changes with one that will |
| `StringLike` on `sub` (`repo:owner/repo:*`) | Matches every branch, pull request and environment of the repository; it is how a single trust policy ends up assumable from contexts nobody intended |
| Scoping by `job_workflow_ref` (which workflow file may assume the role) | Stronger, and available as an STS condition key. Deferred to C4, when the deploy workflow exists; adding it now would pin the role to the probe workflow |

## Consequences

- The main configuration gains a data source (`aws_iam_policy` by name) and a
  required module input (`permissions_boundary_arn`) in `modules/iot` and
  `modules/ingest`. Applying it requires `bootstrap/ci-identity` first.
- Adding an action to a workload role now means two changes: the module's
  policy (the exact grant) and, if the action is new to the project, the
  boundary (an operator apply). Forgetting the second fails at runtime with
  `AccessDenied`, by design.
- The operator keeps administrator credentials for the bootstrap stacks and for
  emergencies. The pipeline does not replace them.
- Residual risks, accepted and documented:
  - IoT certificates cannot be tagged through Terraform and have random ids,
    so certificate actions are scoped to the account and region only.
  - Tag-based scoping of KMS keys lets the apply role tag another customer
    managed key of the account into scope; today every CMK in the account
    belongs to PyroSense.
  - Object reads and writes on the state bucket are not audited (no trail;
    see the re-evaluated `AVD-AWS-0089` note in `bootstrap/state-backend`).
- `docs/ci-cd.md` section 8 explains the design for a first-time reader.

## Revisit if

- A `prod` environment gets a pipeline: it needs its own apply role, GitHub
  environment and review rules, and object-level auditing of state.
- A second maintainer joins: `github_actor_ids`, and the one-maintainer review
  limits in production readiness, section 9.
- The deploy workflow exists (C4): add `job_workflow_ref` to the apply trust.
- AWS adds a way to tag IoT certificates through Terraform, or the account
  hosts customer managed keys that are not PyroSense's.
- An `AccessDenied` in C3 or C4 shows an action missing from the measured set.
