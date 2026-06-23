# ============================================================
# providers.tf
#
# This file does two things:
#   1. Tells Terraform which plugins to download (the AWS provider)
#   2. Configures where to store the state file
#
# You only need to change this file if you want to switch to
# the S3 backend (see the README for when and why to do that).
# ============================================================

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"

      # The ~> operator means "any 5.x version, but not 6.x".
      # This stops a future major version from quietly breaking our config.
      version = "~> 5.0"
    }
  }

  # ------------------------------------------------------------
  # State backend — local vs S3
  #
  # By default (no backend block), Terraform writes the state file
  # to terraform.tfstate right here in this folder. That is perfectly
  # fine for solo work and this tutorial.
  #
  # When you are working with a team and need everyone to share the
  # same state, uncomment the block below, fill in your bucket name,
  # and run `terraform init` again. Terraform will migrate the state
  # to S3 automatically.
  #
  # Follow the S3 setup steps in README.md before uncommenting.
  # ------------------------------------------------------------

  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"   # the S3 bucket you created
  #   key            = "project-1/terraform.tfstate"   # path inside the bucket
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"               # prevents concurrent deploys
  #   encrypt        = true                            # encrypts the state file at rest
  # }
}

# Tell the AWS provider which region to deploy into.
# The actual value comes from var.aws_region in variables.tf.
provider "aws" {
  region = var.aws_region
}
