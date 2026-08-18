# Screenshots

Four, each with a visible timestamp, each redacted before committing.

They exist for orientation rather than proof — see `../EVIDENCE.md` for why the
distinction matters and what the stronger forms of verification are.

| File | What it shows | Why it is worth having |
|---|---|---|
| `01-cloudwatch-dashboard.png` | The `homelab-dashboard` with all four widgets populated | The layout is defined in `terraform/modules/monitoring/main.tf` — 2×2, CPU and network from EC2, memory and disk from the agent. The screenshot should match that file. If it does not, the code is not what is deployed. |
| `02-alarm-ok.png` | Both alarms in `OK` state, with history | An alarm that has never left `INSUFFICIENT_DATA` is not monitoring anything. The state history is the part to look at. |
| `03-alarm-email.png` | The SNS email from the CPU alarm firing | The only artifact that exercises the whole path end to end: CPU → metric → alarm → SNS → inbox. Worth more than the other three combined. |
| `04-terminal.png` | `docker ps` showing `(healthy)`, `curl /health` returning 200, `systemctl status homelab` | Ties the container, the app and the systemd unit together in one frame. |

## Getting number 3 — the one that matters

The alarm email is the only screenshot that proves a pipeline rather than a
state. Producing it means deliberately breaching the alarm:

```bash
ssh -i ~/.ssh/homelab ubuntu@<public_ip>
bash /opt/homelab/scripts/stress_test.sh
```

The default is 360 seconds: the alarm needs five consecutive one-minute periods
above 80%, and six minutes gives a period of margin. The instance will be
unresponsive during the run and the SSH session will lag — that is the test
working.

This is safe on cost **because** `terraform/modules/compute/main.tf` pins
`cpu_credits = "standard"`. T3 instances default to `unlimited`, which bills for
sustained CPU above the baseline instead of throttling. On the default setting,
this script is a script for generating a bill. Do not run it if that block has
been removed.

**Check the subscription is confirmed first**, or the alarm fires into nothing
and you will have throttled the instance for no screenshot:

```bash
aws sns list-subscriptions-by-topic --topic-arn <topic-arn> --profile terraform-homelab
```

`SubscriptionArn` must be a real ARN. `PendingConfirmation` means the link in the
first email was never clicked.

Take `02-alarm-ok.png` after the alarm has returned to `OK`, so its state history
shows the transition into and out of `ALARM` rather than a flat line.

## Redaction

Before committing, black out:

- the AWS account ID (top right of the console, and inside every ARN on the page)
- the instance's public IP
- your email address in the SNS screenshot
- any browser tab, bookmark or notification unrelated to this

Keep visible: the instance ID, the region, the availability zone, private
`10.x` addresses, and every timestamp. Those carry the information and give away
nothing. A screenshot cropped so hard it could be of anything is not evidence.
