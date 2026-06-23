# ============================================================
# variables.tf
#
# Variables are Terraform's way of avoiding hardcoded values.
# Instead of scattering "us-east-1" and "t3.micro" throughout
# your code, you define them once here and reference them
# everywhere else as var.aws_region, var.instance_type, etc.
#
# This also means you can reuse the same config for different
# environments without changing any of the actual resource code:
#   terraform apply -var="instance_type=t3.small"   # staging
#   terraform apply -var="instance_type=t3.large"   # production
#
# Or create a terraform.tfvars file (auto-loaded by Terraform):
#   aws_region    = "us-west-2"
#   key_pair_name = "my-key"
# ============================================================

variable "aws_region" {
  description = "The AWS region to deploy everything into."
  default     = "us-east-1"

  # To deploy in a different region, override this:
  # terraform apply -var="aws_region=eu-west-1"
  #
  # Note: make sure your key pair exists in that region too.
}

variable "github_repo" {
  description = "Public GitHub URL of the Next.js app to clone onto each instance."

  # This is the companion repo for the tutorial — it is public so any instance
  # can clone it without credentials. If you are using your own project, swap
  # this out for your repo URL.
  default = "https://github.com/Manu-world/ops-playbook-hub.git"
}

variable "instance_type" {
  description = "EC2 instance type for the web servers."
  default     = "t3.micro"

  # t3.micro is free-tier eligible and enough for this tutorial.
  # If you find the `next build` step is very slow or getting killed,
  # try t3.small — it has 2 GB of RAM vs 1 GB.
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair to attach to instances (for SSH access)."

  # No default here on purpose — we want you to actively set this so you
  # do not end up with instances you cannot SSH into (we learned this the
  # hard way in Part 1b).
  #
  # Use the name exactly as it appears in the AWS console, WITHOUT the .pem extension.
  # Example: if your file is "playbook-key.pem", set this to "playbook-key".
  #
  # Pass it when running:
  #   terraform apply -var="key_pair_name=playbook-key"
  #
  # Or add to terraform.tfvars:
  #   key_pair_name = "playbook-key"
}
