# ==============================================================================
# modules/monitoring/main.tf — CloudWatch alarms, logs, and dashboard
#
# Sets up a complete observability stack for a single EC2 instance:
#   - SNS topic + email subscription for alert delivery
#   - CPU utilization alarm (catches runaway processes)
#   - Status check alarm (catches hardware/hypervisor failures)
#   - Log groups for app and system logs (14-day retention to control costs)
#   - Dashboard with CPU, memory, disk, and network widgets
#
# The CloudWatch Agent running on the instance pushes the custom metrics
# (mem_used_percent, disk_used_percent) — those won't appear until the
# agent is installed and configured via setup.sh.
# ==============================================================================

# --- SNS Topic ---
# Single topic for all homelab alerts. Email subscription requires manual
# confirmation — check your inbox after first `terraform apply`.
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"

  tags = {
    Project = var.project_name
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- CPU Alarm ---
# Fires if average CPU stays above 80% for 5 consecutive minutes.
# Why 80% for 5 min? Single spikes are normal (apt-get, docker build), but
# sustained high CPU usually means something is stuck or under attack.
# "treat_missing_data = notBreaching" prevents false alarms during instance stop/start.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  alarm_description   = "CPU utilization exceeded 80% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5       # 5 consecutive periods must breach
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60      # Each period = 60 seconds
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.instance_id
  }

  # Notify on BOTH alarm and recovery — so you know when the issue resolved
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Project = var.project_name
  }
}

# --- Status Check Alarm ---
# Catches issues that are AWS's fault (hardware failure, loss of network connectivity,
# host software issues). If this fires, the instance is effectively dead.
# "treat_missing_data = breaching" here because missing data likely means the
# instance is unreachable — which is exactly the problem we want to catch.
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.project_name}-status-check-failed"
  alarm_description   = "Instance status check failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2       # 2 consecutive failures (2 minutes) before alarming
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"  # Maximum — if ANY check failed in the period, catch it
  threshold           = 0          # >0 means at least one check failed
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = var.instance_id
  }

  # No ok_actions here — if the instance recovers, you'll see it in the dashboard.
  # Status check failures usually require manual intervention anyway.
  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Project = var.project_name
  }
}

# --- Log Groups ---
# Pre-creating these so Terraform manages their lifecycle (especially retention).
# If the CloudWatch Agent creates them, they default to "never expire" which gets expensive.
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/homelab/app"
  retention_in_days = 14  # 2 weeks is plenty for a homelab — keeps costs near zero

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "system_logs" {
  name              = "/homelab/system"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

# --- Dashboard ---
# A single-pane-of-glass view. Four widgets arranged in a 2x2 grid:
#   Top-left:     CPU utilization (native EC2 metric)
#   Top-right:    Memory usage (custom metric from CloudWatch Agent)
#   Bottom-left:  Disk usage (custom metric from CloudWatch Agent)
#   Bottom-right: Network I/O (native EC2 metric)
#
# Widget coordinates: x=column (0 or 12), y=row (0 or 6). Each widget is 12x6.
# Total dashboard width is 24 units.
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", var.instance_id]
          ]
          period = 300   # 5-minute aggregation — smooths out short spikes
          stat   = "Average"
          region = var.aws_region
          title  = "CPU Utilization"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            # CWAgent namespace — these metrics only appear after the agent is running
            ["CWAgent", "mem_used_percent", "InstanceId", var.instance_id]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Memory Usage %"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            # Disk metric includes path and fstype dimensions to identify the root volume
            ["CWAgent", "disk_used_percent", "InstanceId", var.instance_id,
             "path", "/", "fstype", "ext4"]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Disk Usage %"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            # Both directions on one chart for quick visual comparison
            ["AWS/EC2", "NetworkIn", "InstanceId", var.instance_id],
            ["AWS/EC2", "NetworkOut", "InstanceId", var.instance_id]
          ]
          period = 300
          stat   = "Sum"   # Sum = total bytes in the period (not average rate)
          region = var.aws_region
          title  = "Network I/O"
        }
      }
    ]
  })
}
