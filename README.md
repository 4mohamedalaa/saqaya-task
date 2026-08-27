# Systems Engineer / DevOps Take-Home

This repository contains a production-oriented response to the three parts of the assignment.

## Part 1 — Multi-tier log aggregator

### Critical analysis

The original block is unsafe and fragile in production:

1. The security group permits every protocol and port from `0.0.0.0/0`. A queue-based worker does not need inbound internet traffic at all.
2. A single EC2 instance is a single point of failure and cannot respond to changing load.
3. Logs exist only on the instance, so an instance or volume failure can lose data. There is no buffer, retry policy, or dead-letter handling.
4. The AMI ID is hard-coded and region-specific. It will eventually become outdated and may not exist in another region.
5. `security_groups` uses an EC2-Classic/name-oriented interface. In a VPC, security groups should be attached by ID with `vpc_security_group_ids`.
6. There is no explicit VPC/subnet placement, multi-AZ strategy, instance role, encryption, monitoring, health check, or controlled administration path.
7. `t2.micro` is an arbitrary fixed size for a workload described as high volume. Capacity should be measured and scaled from backlog and processing time.

### Proposed design

```text
log producers
     │
     ▼
 encrypted SQS queue ── failed messages ──► dead-letter queue
     │
     ▼
 EC2 Auto Scaling Group in private subnets across 2+ AZs
     │                                      │
     ├── processed log objects ────────────► encrypted/versioned S3
     └── metrics and application logs ─────► CloudWatch
```

SQS decouples ingestion from processing, preserves messages across instance replacement, and supplies retries plus a dead-letter queue. It fits independent log events where strict global ordering is not required. If ordering, replay, or multiple independent consumers were requirements, I would select Kinesis instead.

The workers have no inbound security-group rules. They run in private subnets and reach AWS APIs through VPC endpoints or controlled NAT egress. Operators should use Systems Manager Session Manager rather than SSH. The instance profile is limited to consuming this queue, writing to this bucket, publishing metrics, and using SSM.

The Auto Scaling Group spans multiple availability zones. Desired capacity tracks queue backlog per instance, computed with CloudWatch metric math as visible messages divided by in-service instances; raw queue depth does not fall as capacity rises, so target tracking cannot converge on it. Terraform hands ownership of desired capacity to that policy so an apply does not reset the fleet mid-load. Production should also alarm on oldest-message age, dead-letter count, processing failures, and an empty healthy-instance count. S3 supplies the durable destination, with public access blocked, versioning, encryption, and lifecycle rules that expire noncurrent versions and abort incomplete multipart uploads, so the retention limit actually removes data rather than hiding it behind delete markers.

The Terraform in [`infra/main.tf`](infra/main.tf) demonstrates the core resources. It intentionally accepts an existing VPC and private subnets so it can fit an established network and does not pretend that one take-home module defines an organization's networking policy.

Operational details I would add before a real launch include an immutable application image or pinned artifact, VPC endpoints, centralized KMS key policy, S3 retention requirements, dashboards, alarms, load testing, and a tested poison-message replay procedure.

## Part 2 — robust log analysis

The supplied pipeline expects `Username=[alice]`, but the example in the assignment is `Username[alice]`; that discrepancy alone produces no matches. It also depends on non-portable `grep -P`, silently ignores malformed records, and makes multiple full passes through the data. `sort` can become a disk and runtime bottleneck for a very large file. Without `set -o pipefail`, failures in early pipeline stages can also be masked.

The Python implementation streams the file once, accepts both shown username formats, reports malformed failed-login records, and produces deterministic results. It deliberately rejects empty usernames. Memory grows with the number of distinct usernames; at extreme cardinality I would aggregate in the ingestion platform or use a bounded heavy-hitters algorithm.

Run it with:

```bash
python3 src/top_failed_logins.py app.log --limit 5
```

Example output:

```text
12 alice
8 bob
```

Run the automated tests with:

```bash
python3 -m unittest discover -s tests -v
```

The program returns a non-zero exit code for unreadable input or invalid arguments. Malformed failed-login lines are summarized on stderr without contaminating machine-readable stdout.

## Part 3 — three-step production triage

1. **Stabilize and establish scope.** Pause the rollout and shift traffic back to the known-good blue target group if its health is confirmed. Record the deployment and alarm times. Check ALB `RequestCount`, target response time, target 5xx/reset counts, and healthy targets; check RDS CPU, connections, read IOPS, latency, and queue depth. Useful first commands include `aws cloudwatch get-metric-data`, `aws logs tail`, `aws elbv2 describe-target-health`, `curl` against health endpoints, and `ss -s`/`top` on hosts or equivalent container telemetry.
2. **Correlate new application behavior with database work.** Compare blue and green request rates, logs, traces, and queries per request. Use CloudWatch Logs Insights and distributed tracing, then RDS Performance Insights/top SQL and database-native views such as PostgreSQL `pg_stat_activity`/`pg_stat_statements` or MySQL Performance Schema. Identify query fingerprints, callers, wait events, lock contention, connection saturation, and whether requests continue after clients disconnect.
3. **Test the competing hypotheses and remediate.** A query fingerprint appearing only on green, repeated queries per request, retry loops, N+1 access, or a bypassed cache indicates a deployment regression; keep green drained, reproduce with one canary, fix it, and redeploy. An unchanged query mix with poor execution plans, high rows scanned, missing indexes, storage latency, locks, or capacity saturation indicates a database/query limitation; mitigate with caching/read replicas or temporary scaling, then fix indexes or queries using `EXPLAIN (ANALYZE, BUFFERS)` in a safe non-production reproduction. Do not run expensive diagnostic plans on the overloaded primary.

Rollback is the first containment action, not the end of the investigation. Preserve metrics, traces, query samples, and the green build identifier for the incident review.
