terraform {
  required_version = ">= 1.5"   # Minimum Terraform version required

  required_providers {
    aws = {
      source  = "hashicorp/aws"  # Official AWS provider from Terraform registry
      version = "~> 5.0"         # Use any 5.x version (not 6.x)
    }
  }
}

