# ─── Security Group: Internal ALB ─────────────────────────────────────────
# POC:        internal=false, allow port 80 from corporate_ip_ranges (your IP or 0.0.0.0/0)
# Production: internal=true, allow port 443 from VPN CIDR only
# ─────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Security group for Jenkins ALB"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

# Allow HTTP from your IP / corporate range
# POC: corporate_ip_ranges = ["0.0.0.0/0"] allows all
# Better: set to your specific IP ["YOUR.IP.HERE/32"]
resource "aws_security_group_rule" "alb_http_inbound" {
  count             = length(var.corporate_ip_ranges)
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.corporate_ip_ranges[count.index]]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP inbound from ${var.corporate_ip_ranges[count.index]}"
}

# Allow within VPC (for health checks from ALB to Jenkins master)
resource "aws_security_group_rule" "alb_http_vpc" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from within VPC"
}

resource "aws_security_group_rule" "alb_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "All outbound"
}

# HTTPS RULES (add when ACM cert is ready)
# resource "aws_security_group_rule" "alb_https_inbound" {
#   count             = length(var.corporate_ip_ranges)
#   type              = "ingress"
#   from_port         = 443
#   to_port           = 443
#   protocol          = "tcp"
#   cidr_blocks       = [var.corporate_ip_ranges[count.index]]
#   security_group_id = aws_security_group.alb.id
#   description       = "HTTPS inbound from ${var.corporate_ip_ranges[count.index]}"
# }