locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ─── VPC ───────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.common_tags, {
    Name        = "${local.name_prefix}-vpc"
    Environment = var.environment
  })
}

# ─── Internet Gateway ──────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

# ─── Public Subnets ────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Do NOT assign public IPs automatically - we control this explicitly
  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-public-subnet-${count.index + 1}"
    Tier = "public"
    AZ   = var.availability_zones[count.index]
  })
}

# ─── Private Subnets ───────────────────────────────────────────────────────

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  map_public_ip_on_launch = false

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-private-subnet-${count.index + 1}"
    Tier = "private"
    AZ   = var.availability_zones[count.index]
  })
}

# ─── Elastic IPs for NAT Gateways ─────────────────────────────────────────
# One NAT GW per AZ for high availability

resource "aws_eip" "nat" {
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.main]
}

# ─── NAT Gateways ─────────────────────────────────────────────────────────

resource "aws_nat_gateway" "main" {
  count         = length(var.public_subnet_cidrs)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-nat-gw-${count.index + 1}"
    AZ   = var.availability_zones[count.index]
  })

  depends_on = [aws_internet_gateway.main]
}

# ─── Route Tables ─────────────────────────────────────────────────────────

# Public Route Table - routes to IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables - one per AZ, routes to respective NAT GW
resource "aws_route_table" "private" {
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-private-rt-${count.index + 1}"
    AZ   = var.availability_zones[count.index]
  })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ─── VPC Flow Logs ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${local.name_prefix}-flow-logs"
  retention_in_days = 90

  tags = var.common_tags
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${local.name_prefix}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${local.name_prefix}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-vpc-flow-log"
  })
}

# ─── Network ACLs ─────────────────────────────────────────────────────────
# NACLs are stateless - you need both inbound and outbound rules
# They are a second layer of defense AFTER Security Groups

  resource "aws_network_acl" "public" {
    vpc_id     = aws_vpc.main.id
    subnet_ids = aws_subnet.public[*].id

    # ── Inbound: HTTP port 80 (for internet-facing ALB in POC) ───────────────
    # PRODUCTION: remove this rule when ALB is switched to internal=true
    ingress {
      rule_no    = 90
      protocol   = "tcp"
      action     = "allow"
      cidr_block = "0.0.0.0/0"
      from_port  = 80
      to_port    = 80
    }

    # Inbound: HTTPS port 443
    ingress {
      rule_no    = 100
      protocol   = "tcp"
      action     = "allow"
      cidr_block = "0.0.0.0/0"
      from_port  = 443
      to_port    = 443
    }

    # Inbound: SSH for Bastion (restrict to your IP in production)
    ingress {
      rule_no    = 110
      protocol   = "tcp"
      action     = "allow"
      cidr_block = "0.0.0.0/0"
      from_port  = 22
      to_port    = 22
    }

    # Inbound: Ephemeral/return traffic
    ingress {
      rule_no    = 120
      protocol   = "tcp"
      action     = "allow"
      cidr_block = "0.0.0.0/0"
      from_port  = 1024
      to_port    = 65535
    }

    # Outbound: Allow all
    egress {
      rule_no    = 100
      protocol   = "-1"
      action     = "allow"
      cidr_block = "0.0.0.0/0"
      from_port  = 0
      to_port    = 0
    }

    tags = merge(var.common_tags, {
      Name = "${local.name_prefix}-public-nacl"
    })
  }