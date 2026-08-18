# My Cloud Homelab

[![CI](https://github.com/OlajuwonOkeniyi/my-cloud-homelab/actions/workflows/ci.yml/badge.svg)](https://github.com/OlajuwonOkeniyi/my-cloud-homelab/actions/workflows/ci.yml)
[![Terraform](https://img.shields.io/badge/terraform-%E2%89%A5%201.5-7B42BC)](https://developer.hashicorp.com/terraform)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A single-instance personal server on AWS, defined entirely in Terraform. One
`terraform apply` builds the network, the instance, the monitoring and the
alerting, and the instance configures itself on first boot.

It runs a small Flask service in Docker, kept alive by systemd, with CloudWatch
watching CPU and instance health and SNS emailing me when either goes wrong.

**Built and first deployed on 16 August 2026.** Everything below describes what
this code does and what was observed running it. There are no illustrative
numbers in this README — where a figure would be useful but has not been
measured over a meaningful period, it is left out rather than estimated.

---

## Verifying any of this

This runs on a private instance: SSH is limited to one `/32`, the app binds to
loopback, and the dashboard is in an AWS account nobody else can log into. So it
is fair to ask how a reader would tell whether any of it is real.

The strongest answer is not an artifact. It is that the code is here and it runs:
`terraform apply` in any AWS account produces the same 18 resources, and CI runs
`terraform validate` and `shellcheck` on GitHub's runners on every push, which is
a result I cannot edit. After that, a live demo. Only then screenshots and
snapshots, which are the weakest form and are labelled as such.

[docs/EVIDENCE.md](docs/EVIDENCE.md) sets that out properly, including what none
of it can show — that the instance is up at the moment you are reading. Nothing
in a git repository can show that, and this one is meant to be destroyed and
rebuilt rather than kept alive.

---

## What gets created

`terraform apply` produces 18 resources in one region:

| Layer | Resources |
|---|---|
| **Network** | VPC `10.0.0.0/16`, public subnet `10.0.1.0/24`, internet gateway, route table + association |
| **Compute** | EC2 instance (Ubuntu 22.04, `t3.micro`), key pair, security group, IAM role + instance profile |
| **Monitoring** | 2 CloudWatch alarms, 1 dashboard, 2 log groups, SNS topic + email subscription |

No NAT gateway, no load balancer, no auto-scaling, no Elastic IP. Each of those
would add cost or complexity this does not need.

## Design decisions

**SSH is the only inbound port**, restricted to a single `/32`. The Flask app
binds to `127.0.0.1` inside the instance and is never exposed publicly; reaching
it means an SSH tunnel. That removes an entire category of problem — the app
does not have to be production-hardened because it is not reachable.

**No Elastic IP.** The public address changes if the instance is stopped and
started. For something that runs continuously or is destroyed entirely, that is
an acceptable trade for one less billable resource.

**Burst credits set to `standard`.** T3 instances default to `unlimited` mode,
which bills surplus credits rather than throttling when sustained CPU exceeds
the baseline. Since this repository includes a script that deliberately
saturates the CPU, the default would turn a monitoring test into a charge.
Throttling is the correct failure mode for a homelab.

**Root volume encrypted, 20 GB `gp3`, deleted on termination.** Encryption at
rest costs nothing on modern instance types. `delete_on_termination` means
`terraform destroy` leaves no orphaned volume quietly billing.

## Prerequisites

- Terraform ≥ 1.5
- An AWS account and an **IAM user with programmatic access**, configured as a
  named CLI profile
- An SSH key pair you generated yourself

**A working `aws` CLI is not sufficient.** The CLI can authenticate through
sources the Terraform provider cannot read — `aws login` caches short-lived
credentials that the AWS SDK behind Terraform does not look for. A successful
`aws sts get-caller-identity` can sit alongside a `terraform plan` that fails
with `no EC2 IMDS role found`, which reads as though Terraform expected to be
running on an EC2 instance. If you hit that, the credentials are the cause.

**Check which instance types are free-tier eligible for your account** before
choosing one. AWS replaced the twelve-month free tier for accounts created on
or after 15 July 2025 with a credit-based plan, and changed the eligible list:

```bash
aws ec2 describe-instance-types \
  --filters Name=free-tier-eligible,Values=true \
  --query "InstanceTypes[*].[InstanceType]" --output text
```

`t2.micro` is not on the new list. `t4g` variants are, but they are ARM and the
AMI filter in `modules/compute` matches `amd64`, so selecting one fails to
resolve an image.

## Deploying

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab -C homelab

cd terraform
cp terraform.tfvars.example terraform.tfvars
# fill in: aws_profile, ssh_public_key, allowed_ssh_cidr, alert_email

terraform init
terraform plan -out=homelab.tfplan
terraform apply homelab.tfplan
```

`allowed_ssh_cidr` is your public address as a `/32` — `curl https://checkip.amazonaws.com`.
Home connections rotate this; if SSH stops working later, that is the first
thing to check.

**Apply finishing does not mean the homelab is ready.** It means AWS created
the instance. The first-boot bootstrap then runs for several minutes —
system upgrade, Docker, the CloudWatch agent, the image build — and ends with a
reboot. Expect SSH to drop partway through; that is the script working.

**Confirm the SNS subscription.** AWS emails a confirmation link on first apply.
Until it is clicked, every alarm fires into nothing, silently.

```bash
ssh -i ~/.ssh/homelab ubuntu@$(terraform output -raw instance_public_ip)

cloud-init status --long
sudo tail -30 /var/log/homelab-bootstrap.log
docker ps
curl -s localhost:5000/health
```

To reach the app from a laptop:

```bash
ssh -i ~/.ssh/homelab -L 5000:127.0.0.1:5000 ubuntu@<public_ip>
# then open http://localhost:5000
```

## Tearing down

```bash
cd terraform
terraform destroy
```

Nothing is created outside Terraform's state, so nothing is left behind. The app
holds no persistent data — a rebuild is the intended way to update the instance,
not a repair.

## How it is monitored

Three layers, cheapest first.

**A cron health check** runs every five minutes, curls `/health`, and appends
timestamp, status code, response time and a healthy flag to
`/opt/homelab/logs/uptime.csv`. It rotates itself at 10,000 rows. This is the
only record that survives CloudWatch being unavailable, and it is the source of
any uptime figure this project ever quotes.

**The live file is not committed** — it belongs to a running instance, not to
source control, and a file that git rewrites on every deploy is not a log.
Dated snapshots of it are a different thing and do live here, under
`docs/evidence/`, alongside the machine-generated reports described in
[docs/EVIDENCE.md](docs/EVIDENCE.md). One is a moving instrument; the other is an
exhibit with a timestamp on it.

What it has recorded so far, stated with its window rather than dressed up as a
service level: **228 checks over the first 19 hours after deployment, none
failed, mean response time 19.9 ms.** The 138 ms maximum is the first check of
all, before anything was warm. Nineteen hours is not long enough to quote an
uptime percentage from, so there isn't one here — the figure to watch is whether
the count of checks matches the elapsed time, and so far no run has been missed.

**The CloudWatch agent** reports memory and disk usage, which EC2 does not
publish natively. It pushes to the `CWAgent` namespace using the instance's IAM
role, so no credentials live on the box.

**Two alarms, both wired to SNS email.** CPU above 80% averaged over five
consecutive minutes, and any EC2 status check failure. The CPU alarm notifies on
recovery as well as breach; the status check alarm does not, because a failed
status check generally needs a human either way.

A dashboard shows CPU, memory, disk and network in one view. The memory and disk
widgets stay empty until the CloudWatch agent has been running for a few
minutes — they come from the agent, not from EC2.

## Repository layout

```
terraform/            infrastructure
├── main.tf           module wiring
├── provider.tf       AWS provider and profile
├── variables.tf      inputs
├── outputs.tf        IP, instance ID, dashboard URL, SSH command
└── modules/
    ├── networking/   VPC, subnet, IGW, routing
    ├── compute/      EC2, security group, IAM, first-boot bootstrap
    └── monitoring/   alarms, dashboard, SNS, log groups

app/                  Flask service, requirements, Dockerfile
config/
├── docker-compose.yml
└── homelab.service   systemd unit for the compose stack
scripts/
├── setup.sh              first-boot bootstrap, invoked by user_data
├── health_check.sh       cron health check
├── stress_test.sh        saturates CPU to prove the alarm path works
└── collect_evidence.sh   redacted snapshot of the running instance
docs/
├── SETUP_NOTES.md    what deploying it actually taught me
├── RECOVERY.md       runbook
├── EVIDENCE.md       how to verify any of this, strongest method first
├── evidence/         dated snapshots — reports and uptime CSVs
└── screenshots/      dashboard, alarms, alarm email, terminal

.github/workflows/
└── ci.yml            terraform fmt/validate, shellcheck, secret scan
```

## What CI checks

There is nothing here to unit test — the deliverable is infrastructure and the
shell that configures it. There is still plenty to get wrong statically, so CI
runs `terraform fmt -check -recursive` and `terraform validate` over the module
tree, `shellcheck` over `scripts/`, and a scan asserting that no state file,
`tfvars`, private key or AWS access key ID is tracked. That last one matters
because `.gitignore` is a default rather than a control: it stops an accidental
`git add .` and does nothing about a deliberate `git add -f`.

The shellcheck job runs at `--severity=warning` rather than the default. `setup.sh`
sources `/etc/os-release` to read `VERSION_CODENAME`, which shellcheck reports as
`SC1091` because it cannot follow a file that only exists on the target host.
Failing on that would mean deleting a correct line or disabling the rule, and a
check that has to be silenced to pass is not a check.

## What deploying it for the first time surfaced

The infrastructure code was written before it had ever been applied. Running it
found five defects, four of which would have stopped anyone else using it.

**Nothing put the bootstrap script on the instance.** The README instructed you
to SSH in and run `sudo bash /tmp/setup.sh`, but there was no `user_data`, no
provisioner and no file copy anywhere in the Terraform. That file never existed.
The documented setup path could not work. The instance now clones this
repository on first boot and runs the bootstrap unattended.

**The bootstrap crashed instead of explaining.** With its project files absent,
`setup.sh` logged a helpful note and then died five lines later under `set -e`,
on a `cp` of a file that had never been copied. Missing files are now a checked
precondition with a message that says what to do.

**The chosen instance type was not free-tier eligible.** `t2.micro` is absent
from the eligible list for accounts created after July 2025, so the README's
claim of running at no cost was wrong for any new account.

**The container health check could never pass.** It probed with `curl -f`
against an image built from `python:3.11-slim`, which contains no `curl`. Every
probe failed. The deployed instance reported `Up 8 hours (unhealthy)` while the
endpoint returned `200` throughout — a red status carrying no information, which
is worse than no status at all. It now probes with the interpreter already in
the image.

**The printed SSH command pointed at a file that does not exist.** The output
suggested `~/.ssh/homelab.pem`; `.pem` is the extension AWS uses for keys it
generates, not for one you import.

A sixth is operational rather than a defect: **the instance has no git checkout
it can update from.** `/opt/homelab` is a copy made by `setup.sh`, not a working
tree, and the clone at `/tmp/my-cloud-homelab` is a build artifact in a directory
subject to age-based cleanup. Nothing on the box can `git pull`. A rebuild is the
update mechanism, which is defensible for a stateless instance but was nowhere
documented, and it means a fix applied over SSH is lost at the next apply.

## Two more found by reading the scripts afterwards

Both are in the shell, both are the same shape: code that looks correct and
fails only in the situation it was written for.

**The health check logged the wrong status for every failure.** The probe ended
in `curl ... || echo "000"`. When a connection fails, `curl -w '%{http_code}'`
writes `000` *and* exits non-zero, so the fallback appended a second `000` to
curl's own and the CSV recorded `000000`. Successful checks were fine. The one
column the file exists to capture was wrong on exactly the rows that mattered,
and the runbook told you to look for `000`, which never appeared. Reproduced
against a closed port before and after the fix.

**Interrupting the stress test left the CPU pinned.** The banner says "press
Ctrl+C to stop early". A non-interactive shell sets SIGINT to ignore for
commands it starts asynchronously, so the `yes` workers did not die with the
script — following the instruction on screen killed the only thing that knew
their PIDs and left them running. Confirmed by signalling the process group.
Cleanup now runs from an `EXIT` trap sending SIGTERM, which is not ignored.

## Licence

MIT — see [LICENSE](LICENSE).
