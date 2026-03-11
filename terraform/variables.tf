variable "region" {
  description = "AWS region to deploy all resources into"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives us 65,536 IP addresses."
  default     = "10.0.0.0/16"
}

variable "project_name" {
  description = "Prefix for all resource names makes them easy to find in the console"
  default     = "fintrust"
}

