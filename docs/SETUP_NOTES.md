# Setup Notes

Operational detail that does not belong in the README: what the deploy actually
does, what surprised me when I ran it, and the commands worth keeping.

Everything here was observed on the first real deployment, 16 August 2026.
Where something is a documented AWS behaviour rather than something I measured,
it says so.

---

## The deploy sequence, as it actually runs

There is no manual bootstrap step. Earlier versions of this repository told you
to SSH in and run `setup.sh` by hand; nothing in the Terraform ever put that
file on the instance, so that path could not work. `user_data` now does it.

1. `terraform apply` creates 18 resources. The apply returns in roughly three
   minutes.
2. cloud-init runs `user_data`, which installs `git`, clones this repository to
   `/tmp/my-cloud-homelab`, and hands over to `scripts/setup.sh`.
3. `setup.sh` upgrades packages, installs Docker CE and the Compose plugin,
   installs and configures the CloudWatch agent, copies the project to
   `/opt/homelab`, installs and starts the systemd unit, installs the health
   check cron, hardens SSH, then reboots.
4. After the reboot the container is up and `curl localhost:5000/health`
   returns `200`.

**Apply returning is not the same as the homelab being ready.** The apply
finishes when AWS has created the instance; the bootstrap then runs for several
minutes on its own. If you SSH in immediately you will land midway through and
the session will drop when the script reboots.

To watch it:

```bash
cloud-init status --long
sudo tail -f /var/log/homelab-bootstrap.log
```

`/var/log/homelab-bootstrap.log` is written by `user_data` itself.
`/var/log/homelab-setup.log` is written by `setup.sh` once it takes over. If
something fails, the first tells you whether the clone worked and the second
tells you how far the bootstrap got.

---

## Things that cost me time

### `aws` working is not the same as Terraform working

`aws sts get-caller-identity` succeeded and `terraform plan` failed with:

```
no EC2 IMDS role found in the metadata service
```

which reads as though Terraform expected to be running on an EC2 instance.
`aws configure list` showed the credential type as `login`. The CLI's
`aws login` cache lives in `~/.aws/login` and the AWS SDK for Go - which is
what Terraform uses - does not look there. The two tools do not share that
credential source.

The fix was an IAM user with a long-lived access key in a named profile, and a
`profile` argument on the provider. `terraform/provider.tf` carries a comment
explaining this so the next person does not lose the same hour.

### A new IAM user has no permissions at all

Creating the user does not grant anything. The first plan failed on
`UnauthorizedOperation` for `ec2:DescribeImages` - the AMI lookup, the very
first read. The policy has to be attached separately, and it has to be done as
an identity that already has permission to attach policies:

```bash
aws iam attach-user-policy \
  --user-name terraform-homelab \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

`AdministratorAccess` is more than this needs. Replacing it with a policy scoped
to the resources in `terraform/` is on my list; it is a good exercise precisely
because the failure mode is a plan that stops on the first denied call and
tells you exactly which one.

### `t2.micro` is no longer free-tier eligible

AWS replaced the twelve-month free tier for accounts created on or after
15 July 2025 with a credit-based plan, and changed the eligible instance list.
`t2.micro` is not on it. Check for your own account rather than assuming:

```bash
aws ec2 describe-instance-types \
  --filters Name=free-tier-eligible,Values=true \
  --query "InstanceTypes[*].[InstanceType]" --output text
```

`t4g` variants are eligible but are ARM. The AMI filter in `modules/compute`
matches `amd64`, so choosing one fails at image resolution rather than at boot,
which at least fails early.

### T3 burst credits default to `unlimited`, and that bills

This is the one I would have got wrong by carrying over t2 habits. T2 instances
launch in `standard` mode: exhaust your CPU credits and you are throttled to the
baseline. T3, T3a and T4g launch in **`unlimited`** mode: exhaust your credits
and AWS keeps you at full speed and charges for the surplus.

This repository ships `scripts/stress_test.sh`, whose entire purpose is to
saturate the CPU long enough to trip the alarm. On a `t3.micro` left at the
default that is a script designed to generate a bill. The module now sets:

```hcl
credit_specification {
  cpu_credits = "standard"
}
```

Throttling is the correct failure mode here. Being slowed down is the signal;
being charged is not. Watch `CPUCreditBalance` in CloudWatch if you run the
stress test - with `standard`, exhausting it throttles to baseline until credits
accumulate again, so back-to-back runs are not useful.

### CloudWatch agent metrics need the instance profile

The agent starts cleanly whether or not it can authenticate and fails to push
metrics silently - the dashboard's memory and disk widgets simply stay empty.
`CloudWatchAgentServerPolicy` on the instance role is what makes them appear.
When they are blank, check the agent's own log before suspecting the config:

```bash
sudo tail -50 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

### Docker log collection depends on the logging driver

The agent picks up container logs with a glob over
`/var/lib/docker/containers/<id>/<id>-json.log`. That path only exists with the
`json-file` driver. Changing the driver silently ends log shipping.

### The instance has no git checkout it can update from

`/opt/homelab` is a copy made by `setup.sh`, not a working tree. The clone at
`/tmp/my-cloud-homelab` is a build artifact of the bootstrap, and `/tmp` on
Ubuntu is subject to age-based cleanup by `systemd-tmpfiles`, so it is not
somewhere to keep a checkout. Either way, nothing on the box can `git pull`.

I had this wrong at first and it is worth recording why. An early attempt to `cd`
into `/tmp/my-cloud-homelab` failed with `No such file or directory`, and I put
that down to `/tmp` being wiped on reboot. It was not: that deployment had no
`user_data` at all, so the clone had never happened. The directory was missing
because nothing had ever created it. Nineteen hours and one reboot later the
clone from the fixed bootstrap was still present, which is what showed the
original explanation to be wrong.

The general lesson is the one worth keeping: a plausible mechanism that predicts
the symptom is not the same as the cause, and "the file is gone" and "the file
was never written" look identical from the error message.

That is a defensible design for something meant to be rebuilt rather than
patched, but it was not deliberate and it was nowhere documented. If you want to
change something on a running instance you either edit `/opt/homelab` in place
and restart the unit, or re-clone:

```bash
git clone --depth 1 https://github.com/OlajuwonOkeniyi/my-cloud-homelab.git /tmp/my-cloud-homelab
```

The intended path is `terraform apply` after pushing the change.

### Security groups, not NACLs

Security groups are stateful; return traffic for an allowed inbound connection
is automatically permitted. Network ACLs are stateless and would need an
explicit ephemeral-port rule for the reply. The default NACL is left alone
deliberately - SSH access is controlled entirely by the security group's single
`/32` rule.

---

## Client-side setup on Windows

Two things caught me that are PowerShell rather than AWS.

`ssh-keygen` does not create the directory it writes into. On a machine that has
never used SSH, `~/.ssh` does not exist and the key generation fails with
`No such file or directory`:

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.ssh"
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\homelab" -C homelab
```

PowerShell splits native arguments on `=`, so `terraform plan -out=homelab.tfplan`
arrives as two arguments and Terraform reports "Too many command line
arguments". Quote the whole thing:

```powershell
terraform plan "-out=homelab.tfplan"
```

### Line endings are a deployment concern, not a style preference

This repository is authored on Windows and executed on Linux. A shell script
saved with CRLF endings does not run at all - the kernel reads the shebang as
`/usr/bin/env bash\r` and reports:

```
/usr/bin/env: 'bash\r': No such file or directory
```

Whether that reaches the instance depends on `core.autocrlf`, which Git for
Windows sets to `true` by default and which converts on commit. Relying on a
client-side default to keep production scripts executable is not a control, so
`.gitattributes` pins it instead:

```
*.sh text eol=lf
```

To check what is actually stored rather than what your working copy looks like:

```bash
git ls-files --eol scripts/
```

`w/crlf i/lf` means the index is correct and only the checkout is Windows-style.
`i/crlf` on a `.sh` file means the broken version is what the instance clones.
`git add --renormalize .` rewrites the index to match `.gitattributes`.

On the instance itself, one command settles it:

```bash
head -c 21 /usr/local/bin/health_check.sh | od -c | head -2
```

---

## Reaching the app

The Flask container binds to `127.0.0.1` inside the instance and the security
group allows only port 22, so the app is not reachable from the internet at all.
Access is over an SSH tunnel:

```bash
ssh -i ~/.ssh/homelab -L 5000:127.0.0.1:5000 ubuntu@<public_ip>
# then open http://localhost:5000
```

The key is the one you generated. It has no `.pem` extension - `.pem` is what
AWS names keys it generates for you, not keys you import.

---

## Commands worth keeping

```bash
# app
systemctl status homelab
docker ps
docker logs homelab-app --tail 50
systemctl restart homelab

# bootstrap forensics
cloud-init status --long
sudo tail -50 /var/log/homelab-bootstrap.log
sudo tail -50 /var/log/homelab-setup.log

# cloudwatch agent
systemctl status amazon-cloudwatch-agent
sudo tail -50 /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log

# health check history
tail -20 /opt/homelab/logs/uptime.csv
/usr/local/bin/health_check.sh && tail -1 /opt/homelab/logs/uptime.csv
```

---

## Tearing down

```bash
cd terraform
terraform destroy
```

The app holds no persistent data - the notes it stores are in memory and go with
the container. Nothing is created outside Terraform's state, so a destroy leaves
nothing behind. If persistent data is ever added, an EBS snapshot step belongs
here before the destroy.
