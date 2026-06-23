# ============================================================
# outputs.tf
#
# Outputs are what Terraform prints in your terminal after
# `terraform apply` finishes. Think of them as the return
# value of your infrastructure run.
#
# Without this, you would have to go digging in the AWS
# Console to find your load balancer's DNS name. With it,
# Terraform hands it to you directly at the end of the deploy.
# ============================================================

output "load_balancer_dns" {
  description = "The public DNS name of the load balancer — paste this into your browser to see the app."
  value       = aws_lb.app_alb.dns_name
}

# After `terraform apply` completes, you will see something like:
#
#   Apply complete! Resources: 10 added, 0 changed, 0 destroyed.
#
#   Outputs:
#
#   load_balancer_dns = "playbook-tf-alb-1234567890.us-east-1.elb.amazonaws.com"
#
# Wait 3-5 minutes after seeing this for the instances to finish
# booting and building the app, then paste the DNS name into your browser.
