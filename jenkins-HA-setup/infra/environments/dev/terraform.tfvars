environment             = "prod"
aws_region              = "us-east-1"
jenkins_instance_type   = "t3.xlarge"    # prod gets more resources
jenkins_ami_id          = "ami-0abcdef1234567890"
vpc_cidr                = "10.10.0.0/16"
private_subnet_cidrs    = ["10.10.1.0/24", "10.10.2.0/24"]
public_subnet_cidrs     = ["10.10.101.0/24", "10.10.102.0/24"]
allowed_vpn_cidr        = "10.0.0.0/8"   # your corporate VPN range