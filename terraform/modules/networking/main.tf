# ==============================================================================
# modules/networking/main.tf - VPC and public subnet infrastructure
#
# Creates an isolated network for the homelab with internet access.
# Architecture is intentionally simple: one VPC, one public subnet, one IGW.
# No NAT gateway (saves ~$30/month) since our instance needs a public IP anyway.
#
# If you later want private subnets (e.g., for a database), add them here
# with a NAT gateway for outbound access.
# ==============================================================================

# --- VPC ---
# /16 gives us 65,536 IPs - way more than needed, but it's free and leaves
# room to carve out additional subnets later without re-IPing anything.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true # Gives instances public DNS names (useful for SSH)
  enable_dns_support   = true # Required for DNS hostnames to work

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# --- Public Subnet ---
# /24 = 254 usable IPs. Placed in AZ "a" of whatever region we're deploying to.
# map_public_ip_on_launch means any instance launched here gets a public IP
# automatically - no need to allocate an Elastic IP for a single-instance setup.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

# --- Internet Gateway ---
# Attaches to the VPC and provides the route to the public internet.
# Without this, nothing in the VPC can reach the outside world.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

# --- Route Table ---
# Sends all non-local traffic (0.0.0.0/0) through the internet gateway.
# Local VPC traffic (10.0.0.0/16) is implicitly routed - no rule needed.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

# --- Route Table Association ---
# Explicitly links our subnet to the public route table. Without this,
# the subnet uses the VPC's "main" route table (which has no internet route).
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
