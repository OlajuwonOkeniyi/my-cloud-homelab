# My Cloud Homelab

This is my personal cloud dev server. I set it up because I wanted somewhere reliable to run scripts and host small projects without worrying about my laptop being open.

The whole thing runs on a single EC2 instance with monitoring, auto-recovery, and alerting baked in. It's not fancy — it's just solid. I've had it running for weeks without touching it, which is exactly the point.

## Tech Stack

| Layer | Tool | Why |
|-------|------|-----|
| Infrastructure | Terraform | Repeatable deploys, easy teardown when I'm not using it |
| Compute | AWS EC2 (t2.micro) | Free tier eligible, enough for personal stuff |
| OS | Ubuntu 22.04 LTS | Stable, familiar, good package support |
| Application | Python Flask in Docker | Simple HTTP service I use as a scratchpad API |
| Process Mgmt | systemd | Auto-restarts the container if it dies |
| Monitoring | CloudWatch + SNS | Alerts me before things break |
| Logs | CloudWatch Logs + local CSV | Centralized logs + a quick local audit trail |

## Quick Start

```bash
# Clone and configure
git clone https://github.com/yourusername/my-cloud-homelab.git
cd my-cloud-homelab/terraform

# Set your variables (or use a .tfvars file)
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your SSH key, alert email, etc.

# Deploy
terraform init
terraform plan
terraform apply

# After the instance is up, SSH in and run the bootstrap
ssh -i ~/.ssh/your-key.pem ubuntu@<public_ip>
sudo bash /tmp/setup.sh
```

## Architecture

Everything lives on one EC2 instance inside a custom VPC:

- **VPC** with a public subnet and internet gateway — nothing complex, just clean isolation from default VPC clutter.
- **Security Group** locked to SSH (port 22) from my IP only. The Flask app listens on localhost inside the instance; I access it over an SSH tunnel when I need to.
- **EC2 instance** running Ubuntu 22.04. Docker hosts the Flask app, systemd keeps it alive, and the CloudWatch agent ships logs out.
- **CloudWatch** monitors CPU, disk, memory (via the agent), and container health. If CPU stays above 80% for 5 minutes or the health check fails, SNS sends me an email.
- **CloudWatch Logs** stores application logs and system-level logs from the instance, so I can debug without SSH-ing in.

No load balancer, no auto-scaling, no multi-AZ. It's a homelab — I'd rather keep it simple and actually understand every piece.

## Key Metrics

| Metric | Value |
|--------|-------|
| Uptime (last 14 days) | 99.7% |
| Avg response time | 12ms |
| Monthly cost | ~$0 (free tier) |
| Time to redeploy from scratch | ~8 minutes |
| Longest unplanned outage | 23 minutes (my fault — see RECOVERY.md) |

## Project Structure

```
my-cloud-homelab/
├── README.md
├── LICENSE
├── .gitignore
├── terraform/           # All infrastructure as code
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── provider.tf
│   └── modules/
│       ├── networking/  # VPC, subnet, IGW, route table
│       ├── compute/     # EC2, security group, key pair
│       └── monitoring/  # CloudWatch alarms, dashboard, SNS, log groups
├── app/                 # The Flask application
│   ├── server.py
│   ├── requirements.txt
│   └── Dockerfile
├── config/
│   ├── docker-compose.yml
│   └── homelab.service  # systemd unit for the container
├── scripts/
│   ├── setup.sh         # EC2 bootstrap (runs once after launch)
│   ├── health_check.sh  # Cron job — pings app, logs result
│   └── stress_test.sh   # Hammers CPU to trigger CloudWatch alarm
├── docs/
│   ├── SETUP_NOTES.md   # What I learned setting this up
│   └── RECOVERY.md      # Incident runbook
└── logs/
    └── uptime_sample.csv  # 14 days of health check data
```

## How Monitoring Works

Three layers, from cheapest to most informative:

1. **Local health check** — A bash script runs every 5 minutes via cron. It curls the Flask app's `/health` endpoint and appends the result (timestamp, HTTP status, response time) to a CSV. Dead simple, works even if CloudWatch is having a bad day.

2. **CloudWatch Metrics** — The CloudWatch agent on the instance reports memory and disk usage (EC2 doesn't give you those natively). Combined with the built-in CPU metric, I have a solid picture of resource usage.

3. **CloudWatch Alarms + SNS** — Two alarms:
   - CPU > 80% sustained for 5 minutes → email alert
   - Health check failures (StatusCheckFailed) → email alert
   
   I also have a CloudWatch dashboard that shows CPU, memory, disk, and network in one view. Mostly I check it when I'm bored, but it's been useful a couple times for spotting slow memory leaks.

## Lessons Learned

- **systemd is underrated.** I spent way too long looking at container orchestrators before realizing that for a single container on a single host, a systemd unit with `Restart=always` is all you need.
- **Don't skip the health check.** I had a silent failure early on where the container was "running" but the app inside had crashed. The cron health check caught it within 5 minutes. CloudWatch would have caught it too, but having local evidence made debugging faster.
- **Terraform modules are worth it even for small projects.** My first version was one giant `main.tf` and it was miserable to work with. Splitting into networking/compute/monitoring made each piece easy to reason about.
- **Free tier is generous but has edges.** CloudWatch custom metrics cost money if you're not careful. I keep it to 3 custom metrics to stay in the free tier.
- **SSH-only security groups are surprisingly freeing.** No public ports means I don't worry about the app being production-hardened. I just tunnel in when I need access.

## License

MIT — see [LICENSE](LICENSE).