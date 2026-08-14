# Setup Notes

Things I figured out along the way. Writing them down so I don't Google the same stuff twice.

## Initial Setup Sequence

1. `terraform apply` creates the infrastructure (~3 minutes)
2. SSH into the instance
3. Clone/copy the repo to `/tmp/my-cloud-homelab`
4. Run `sudo bash /tmp/my-cloud-homelab/scripts/setup.sh`
5. Wait for reboot (~1 minute)
6. Verify: `curl http://127.0.0.1:5000/health`

## Things That Tripped Me Up

### CloudWatch Agent Permissions

The EC2 instance needs an IAM instance profile with `CloudWatchAgentServerPolicy` attached. Without it, the agent starts fine but silently fails to push metrics. I spent an hour on this before checking the agent logs at `/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log`.

### Docker Log Paths

Docker stores container logs at `/var/lib/docker/containers/<id>/<id>-json.log`. The CloudWatch agent config uses a glob pattern to pick them up. If you change the Docker logging driver, this breaks — keep it on `json-file`.

### Security Group vs. NACL

I initially put the SSH rule in a Network ACL and forgot that NACLs are stateless — you need explicit ephemeral port rules for return traffic. Security groups are stateful, so I just use those and leave the NACL as default allow-all. Simpler.

### t2.micro Burst Credits

t2.micro gets CPU burst credits. If you burn them all (like running the stress test repeatedly), the instance gets throttled to ~10% CPU until credits recover. This is normal — just don't run stress tests back-to-back. Check burst balance in CloudWatch under `CPUCreditBalance`.

### CloudWatch Custom Metrics Costs

Free tier gives you 10 custom metrics. The CloudWatch agent with my config uses 2 (mem_used_percent, disk_used_percent). Stay under 10 total to avoid charges.

## SSH Tunnel for App Access

The Flask app only listens on localhost (port bound to 127.0.0.1 in docker-compose). To access it from my laptop:

```bash
ssh -i ~/.ssh/homelab.pem -L 5000:127.0.0.1:5000 ubuntu@<public_ip>
# Then open http://localhost:5000 in browser
```

## Useful Commands

```bash
# Check app status
systemctl status homelab

# View app logs
docker logs homelab-app --tail 50

# Restart the app
systemctl restart homelab

# Check CloudWatch agent status
systemctl status amazon-cloudwatch-agent

# View health check log
tail -20 /opt/homelab/logs/uptime.csv

# Manually run health check
/usr/local/bin/health_check.sh && tail -1 /opt/homelab/logs/uptime.csv
```

## Tear Down

```bash
cd terraform
terraform destroy
```

Everything is stateless (notes are in-memory), so there's nothing to back up. If I ever add persistent data, I'll add an EBS snapshot to the destroy process.
