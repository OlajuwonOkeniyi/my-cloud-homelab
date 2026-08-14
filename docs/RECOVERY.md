# Recovery Runbook

What to do when things break. Ordered from "most likely" to "least likely."

---

## Scenario 1: App Container Crashed

**Symptom:** Health check CSV shows `000` or `503`. SSH still works.

**Steps:**
```bash
# Check what happened
docker ps -a
docker logs homelab-app --tail 100

# Usually just restart it
systemctl restart homelab

# Verify
curl http://127.0.0.1:5000/health
```

**Root cause (usually):** OOM kill on t2.micro (1GB RAM). Check `dmesg | grep -i oom`. If it's recurring, the app has a memory leak or I'm running too much stuff.

---

## Scenario 2: Instance Unreachable (Can't SSH)

**Symptom:** SSH timeout. CloudWatch shows StatusCheckFailed.

**Steps:**
1. Check EC2 console → Instance state
2. If instance is running but unreachable:
   - Check security group hasn't been modified
   - Verify my IP hasn't changed (update `allowed_ssh_cidr` in tfvars if it has)
3. If status checks are failing:
   ```bash
   # Stop and start (NOT reboot — stop/start migrates to new hardware)
   aws ec2 stop-instances --instance-ids <id>
   aws ec2 start-instances --instance-ids <id>
   ```
4. If that doesn't fix it: `terraform destroy && terraform apply` (nuclear option, takes ~5 min)

**Note:** Public IP changes on stop/start unless you use an Elastic IP. Check `terraform output` for the new IP.

---

## Scenario 3: CloudWatch Alarm Won't Clear

**Symptom:** Getting alarm emails but the app is healthy.

**Steps:**
```bash
# Verify the app is actually healthy
curl http://127.0.0.1:5000/health

# Check CPU is actually normal
top -bn1 | head -5

# Sometimes metrics lag — wait 5 minutes and check CloudWatch console
# If it's stuck, manually set alarm state (resets on next evaluation)
aws cloudwatch set-alarm-state \
    --alarm-name homelab-cpu-high \
    --state-value OK \
    --state-reason "Manual reset after verification"
```

---

## Scenario 4: Disk Full

**Symptom:** App errors, `docker build` fails, logs mention "no space left on device."

**Steps:**
```bash
# Check disk usage
df -h /

# Docker is usually the culprit
docker system prune -af

# Check log rotation is working
ls -lh /opt/homelab/logs/uptime.csv
ls -lh /var/lib/docker/containers/

# If CloudWatch agent logs are huge
journalctl --vacuum-size=100M
```

---

## Scenario 5: Full Rebuild from Scratch

**When:** Everything is borked and I don't want to debug it.

**Steps:**
```bash
cd terraform
terraform destroy -auto-approve
terraform apply -auto-approve
# Wait for instance, then:
ssh -i ~/.ssh/homelab.pem ubuntu@$(terraform output -raw instance_public_ip)
sudo bash /tmp/my-cloud-homelab/scripts/setup.sh
```

**Total time:** ~8 minutes from destroy to healthy app.

---

## Post-Incident

After fixing anything non-trivial:
1. Add a note to this file about what happened and what fixed it
2. Check if the monitoring would have caught it earlier
3. If applicable, update the Terraform config to prevent recurrence

## Incident Log

| Date | Duration | What Happened | Fix |
|------|----------|---------------|-----|
| 2026-07-30 | 23 min | Ran stress_test.sh, forgot to kill it. Burst credits exhausted, app became unresponsive. | Killed the stress processes, waited for credits to recover. Added a note in stress_test.sh about this. |
| 2026-08-02 | 8 min | My ISP changed my IP. SSH blocked by security group. | Updated `allowed_ssh_cidr` in tfvars, ran `terraform apply`. |
