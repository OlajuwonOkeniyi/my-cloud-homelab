# Recovery Runbook

What to do when something breaks, ordered most likely first.

These are procedures, not a history. The incident log at the bottom contains
only what has actually happened - it is short, because this has been running
since 16 August 2026.

---

## Scenario 1: the container is down

**Symptom:** `uptime.csv` shows `000` or `503`. SSH still works.

```bash
docker ps -a
docker logs homelab-app --tail 100
systemctl restart homelab
curl -s localhost:5000/health
```

`docker ps -a` rather than `docker ps` - a container that exited will not appear
in the latter, and "no output" is easy to misread as "no problem".

**Likely causes.** The instance has 1 GiB of RAM, so an out-of-memory kill is
plausible; `dmesg | grep -i oom` confirms or rules it out in one line. The
systemd unit uses `Restart=always`, so a container that merely crashed should
already be back - if it is genuinely down, it is failing to start rather than
having died once, and `docker logs` on the exited container is where the reason
is.

---

## Scenario 2: the container says `unhealthy` but the app answers

**Symptom:** `docker ps` shows `(unhealthy)` while `curl localhost:5000/health`
returns `200`.

**Check the health check itself before you touch the app.** This exact state
happened on first deployment and lasted eight hours: the probe was
`curl -f http://localhost:5000/health`, and the image is built from
`python:3.11-slim`, which does not include `curl`. Every probe failed with
"executable not found" and the container was marked unhealthy while serving
traffic normally the whole time.

```bash
docker inspect --format '{{json .State.Health}}' homelab-app | python3 -m json.tool
```

That prints the last few probe results including their output, which says
whether the probe failed or the app did. The probe in
`config/docker-compose.yml` now uses `python -c` with `urllib` - the interpreter
is guaranteed present because it is what the image is for.

A red status that is always red carries no information and is worse than no
status at all, because it trains you to ignore it.

---

## Scenario 3: SSH times out

**Symptom:** connection hangs. The instance may or may not be healthy.

1. **Check your own IP first.** Home connections rotate. This is the most
   common cause and the cheapest to rule out:

   ```bash
   curl https://checkip.amazonaws.com
   ```

   If it differs from `allowed_ssh_cidr` in `terraform.tfvars`, update the
   variable and `terraform apply`. Change it in the tfvars, not in the console:
   a console edit is drift that the next apply silently reverts.

2. **Check the instance state** in the EC2 console or with
   `aws ec2 describe-instance-status --instance-ids <id>`.

3. **If status checks are failing**, stop and start rather than reboot. A
   stop/start migrates the instance to different physical hardware; a reboot
   keeps it on the same host, which does not help if the host is the problem.

   ```bash
   aws ec2 stop-instances  --instance-ids <id>
   aws ec2 start-instances --instance-ids <id>
   ```

   **The public IP changes on stop/start** - there is no Elastic IP by design.
   Get the new one with `terraform refresh && terraform output instance_public_ip`.

4. If none of that works, rebuild (Scenario 6).

---

## Scenario 4: an alarm will not clear

**Symptom:** alarm emails arriving while the app looks fine.

```bash
curl -s localhost:5000/health
top -bn1 | head -5
```

CloudWatch metrics lag by a few minutes; the CPU alarm needs five consecutive
one-minute periods below threshold before it returns to OK, so give it that long
before assuming it is stuck.

If you have genuinely verified the state and want to force it:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name homelab-cpu-high \
  --state-value OK \
  --state-reason "Manual reset after verification"
```

This only sets the state until the next evaluation. If the metric is still
breaching it will flip straight back - which is a useful test in itself.

**If you are getting no emails at all**, the SNS subscription was probably never
confirmed. AWS sends a confirmation link on first apply and the subscription
stays `PendingConfirmation` until it is clicked, with every alarm firing into
nothing:

```bash
aws sns list-subscriptions-by-topic --topic-arn <arn>
```

---

## Scenario 5: disk full

**Symptom:** the app errors, builds fail, logs mention "no space left on
device".

```bash
df -h /
docker system prune -af          # usually the cause: old images and layers
ls -lh /opt/homelab/logs/uptime.csv
journalctl --vacuum-size=100M
```

`health_check.sh` rotates `uptime.csv` at 10,000 rows, so at one row every five
minutes it is not the culprit - roughly five weeks of data sits in a file of a
few hundred kilobytes. Docker images are almost always what filled the volume.

---

## Scenario 6: full rebuild

**When:** the instance is unrecoverable, or it is faster to rebuild than to
diagnose. Because the instance holds no state, this is a legitimate first
response and not a last resort.

```bash
cd terraform
terraform destroy -auto-approve
terraform apply -auto-approve
```

**Nothing to run by hand afterwards.** `user_data` clones the repository and
runs the bootstrap unattended, so the instance configures itself. Wait, then
verify:

```bash
ssh -i ~/.ssh/homelab ubuntu@$(terraform output -raw instance_public_ip)
cloud-init status --long
docker ps
curl -s localhost:5000/health
```

The bootstrap ends in a reboot, so an SSH session opened too early will drop.
That is the script working, not a failure.

**A rebuild deploys whatever is on the branch in `repo_branch`, not what is on
your laptop.** Push first, or the new instance comes up on the old code.

**The public IP will be different**, and `terraform destroy` does not remove the
old host key from your `known_hosts`. If SSH warns about a changed host key
after a rebuild, that is expected:

```bash
ssh-keygen -R <old_ip>
```

---

## Scenario 7: `terraform plan` cannot authenticate

**Symptom:** `no valid credential sources found`, or
`no EC2 IMDS role found in the metadata service` on a machine that is obviously
not an EC2 instance.

```bash
aws configure list
```

If the credential type shows `login`, the CLI is authenticated through
`aws login`, whose cache Terraform cannot read - the two tools do not share that
source. Use an IAM user access key in a named profile and set `aws_profile` in
`terraform.tfvars`. `docs/SETUP_NOTES.md` has the detail.

---

## After an incident

1. Add a row to the log below - what happened, what fixed it, how long.
2. Ask whether the monitoring would have caught it. Scenario 2 is the standing
   example of monitoring that reported a problem while telling you nothing
   useful about it.
3. If the answer is no, fix the monitoring, not just the instance.
4. If it can be prevented in the Terraform, change the Terraform. A fix applied
   over SSH is lost at the next rebuild.

## Incident log

| Date | Duration | What happened | Fix |
|---|---|---|---|
| 2026-08-16 | ~8 h, no user impact | Container reported `unhealthy` from first boot while `/health` returned `200` throughout. The Compose healthcheck probed with `curl`, which is not present in the `python:3.11-slim` image. | Rewrote the probe to use `python -c` with `urllib`. Fixed in the repository, pulled onto the instance, verified `Up 56 seconds (healthy)`. Scenario 2 above exists because of this. |
