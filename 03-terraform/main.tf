# ============================================================
# main.tf
#
# This is the main blueprint. Everything AWS needs to build our
# scalable web app lives in this one file. The resources are
# organised in the same order we built them in Parts 1a and 1b:
#
#   1. Data sources  — discover existing AWS resources (VPC, subnets)
#   2. Security groups — the bouncers
#   3. Launch template + target group — the training manual + health monitor
#   4. Load balancer + auto scaling group — the host + the manager
#
# One thing worth noticing: we never define *order* here. Terraform
# reads the references between resources (e.g., ec2_sg references
# alb_sg.id) and figures out the correct creation order on its own.
# You just describe *what* you want. Terraform handles the *how*.
# ============================================================


# ==============================================================
# SECTION 1: DATA SOURCES
#
# Data sources are read-only lookups. We are not creating these
# resources — we are asking Terraform to find existing ones in
# our AWS account that we want to deploy into.
# ==============================================================

# Find the default VPC automatically — no need to hardcode an ID.
data "aws_vpc" "default" {
  default = true
}

# Find subnets inside that VPC, but only the public ones.
#
# In Part 1b (CLI edition), we hit what we called the "Private Subnet Trap" —
# blindly grabbing subnets can land you in a private one that has no internet
# access. Instances there cannot download Node.js or clone your repo, so the
# app never starts and the health check fails forever.
#
# This filter solves that problem at the config level. We only get subnets
# where instances automatically receive a public IP, which means they have
# a working path to the internet.
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# Look up the full details of each subnet we found above.
# We need the availability_zone field so we can deduplicate below.
# The for_each makes Terraform fetch the details of every subnet ID
# in parallel — one aws_subnet resource per ID.
data "aws_subnet" "public" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

locals {
  # Two real problems we hit during this series, both fixed here:
  #
  # Problem 1 (ALB error): "A load balancer cannot be attached to
  # multiple subnets in the same Availability Zone."
  # If your VPC has more than one public subnet per AZ (which happens
  # when you've created extra subnets for other projects), passing all
  # of them to the ALB causes this error. The map below keeps only one
  # subnet per AZ — the last one wins if there are duplicates, which
  # is fine since any subnet in that AZ would work.
  #
  # Problem 2 (ASG error): "t3.micro is not supported in us-east-1e."
  # AWS added us-east-1e later and it has limited instance type support.
  # We exclude it so the ASG never tries to launch there.
  # The ... (ellipsis) after the value is the fix for "Duplicate object key".
  # Without it, Terraform errors if two subnets share the same AZ key.
  # With it, Terraform groups them into a list: { "us-east-1c" => ["subnet-abc", "subnet-def"] }
  subnets_by_az = {
    for id, subnet in data.aws_subnet.public :
    subnet.availability_zone => id...
    if subnet.availability_zone != "us-east-1e"
  }

  # Pick the first subnet from each AZ's list. We only need one per AZ —
  # they're all public and equivalent, so the first one is fine.
  unique_subnet_ids = [for az, ids in local.subnets_by_az : ids[0]]
}


# ==============================================================
# SECTION 2: SECURITY GROUPS (THE BOUNCERS)
#
# Same principle as Parts 1a and 1b: EC2 instances must never
# be reachable directly from the internet. Everything must go
# through the load balancer. We enforce this by making the EC2
# security group only accept traffic from the ALB security group.
# ==============================================================

# The ALB's bouncer — lets the public internet in on port 80
resource "aws_security_group" "alb_sg" {
  name        = "playbook-terraform-alb-sg"
  description = "Allow public HTTP traffic to the load balancer"
  vpc_id      = data.aws_vpc.default.id

  # Let anyone on the internet reach the load balancer over HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic from the ALB.
  # Without this, the ALB cannot forward requests to our EC2 instances
  # or receive their responses. AWS does not allow outbound traffic
  # by default once you attach a custom security group.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The EC2 instances' bouncer — only lets the ALB in, on port 3000
resource "aws_security_group" "ec2_sg" {
  name        = "playbook-terraform-ec2-sg"
  description = "Allow traffic only from the load balancer"
  vpc_id      = data.aws_vpc.default.id

  # Only traffic that comes through the ALB security group is allowed in.
  # Notice we are using security_groups = [aws_security_group.alb_sg.id]
  # rather than a CIDR block like "10.0.0.0/8". This is the correct way —
  # it means "only resources in the ALB's security group" not "anyone in
  # this IP range". Terraform knows to create alb_sg first because we
  # reference its ID here.
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Allow all outbound traffic so instances can reach the internet
  # to download packages and clone the repo during the boot script.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# ==============================================================
# SECTION 3: LAUNCH TEMPLATE + TARGET GROUP
#
# The launch template is the "training manual" — the blueprint
# for every new EC2 instance the auto scaling group spins up.
# The target group is where the ALB sends traffic and where it
# checks if instances are healthy.
# ==============================================================

# The training manual: every new instance uses this exact config
resource "aws_launch_template" "app_template" {
  name_prefix   = "playbook-tf-template-"
  instance_type = var.instance_type

  # The SSM parameter path always resolves to the latest stable version
  # of Amazon Linux 2023, so every new instance gets an up-to-date OS
  # without us having to manually update the AMI ID. This is the same
  # approach we used in Parts 1a and 1b.
  image_id = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"

  # Attach the EC2 security group (not the ALB one)
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  # The SSH key so you can connect if something goes wrong.
  # We learned in Part 1b that forgetting this means no SSH access at all.
  key_name = var.key_pair_name

  # user_data is the boot script that runs when each instance starts.
  #
  # templatefile() reads user-data.sh and replaces ${GITHUB_REPO} with
  # the actual value from our variable before handing the script to AWS.
  #
  # base64encode() is required — AWS expects user-data as base64, not
  # plain text. Terraform handles the encoding for us.
  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    GITHUB_REPO = var.github_repo
  }))
}

# The target group: this is how the ALB knows where to send requests
# and how it checks if instances are healthy enough to receive traffic
resource "aws_lb_target_group" "app_tg" {
  name     = "playbook-tf-tg"
  port     = 3000 # our Next.js app listens on port 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    # The ALB hits this path every `interval` seconds.
    # No trailing slash — /api/health/ returns a 308 redirect,
    # not a 200, and the ALB does not follow redirects.
    path = "/api/health"
    port = "traffic-port" # use the same port as the target group (3000)

    # An instance needs 2 passing checks in a row to be marked healthy.
    # This prevents a momentarily slow response from yanking an instance out.
    healthy_threshold = 2

    # An instance needs 2 failing checks in a row to be marked unhealthy.
    # One network hiccup will not remove a good instance.
    unhealthy_threshold = 2

    # Wait up to 4 seconds for the instance to respond to the health check.
    timeout = 4

    # Check every 10 seconds. With 2 failures required, an instance will
    # be marked unhealthy within ~20 seconds of the app going down.
    interval = 10
  }
}


# ==============================================================
# SECTION 4: LOAD BALANCER + AUTO SCALING GROUP
#
# The load balancer is the public entry point — users hit it
# and it routes them to a healthy instance. The auto scaling
# group is the manager — it keeps the right number of instances
# running and replaces broken ones automatically.
# ==============================================================

# The public-facing load balancer
resource "aws_lb" "app_alb" {
  name               = "playbook-tf-alb"
  load_balancer_type = "application"

  # internal = false means it gets a public IP and DNS name.
  # Set to true if you only want it reachable from inside the VPC.
  internal = false

  security_groups = [aws_security_group.alb_sg.id]

  # Spread the ALB across our deduplicated public subnets (one per AZ).
  # If one AWS data centre goes down, the ALB is still up in the other.
  subnets = local.unique_subnet_ids
}

# The listener: when a request comes in on port 80, forward it to our instances
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# The manager: keeps 2 instances running across our public subnets,
# replaces unhealthy ones, and can scale up to 4 under load
resource "aws_autoscaling_group" "app_asg" {
  name = "playbook-tf-asg"

  # Spread instances across our deduplicated public subnets (one per AZ,
  # us-east-1e excluded). This gives us multi-AZ deployment without
  # hitting the AZ/instance-type compatibility issues we saw earlier.
  vpc_zone_identifier = local.unique_subnet_ids

  # Wire the ASG to the load balancer target group
  target_group_arns = [aws_lb_target_group.app_tg.arn]

  # Use the ALB's health check instead of just checking if the EC2
  # machine is on. If the app stops responding on /api/health, the
  # ASG will replace the instance — not just reboot the machine.
  health_check_type = "ELB"

  # Give new instances 5 minutes to boot and finish the user-data
  # script before we start checking their health. Without this,
  # the ASG would terminate instances that are still building the app.
  health_check_grace_period = 300

  min_size         = 2 # never drop below 2 (one per AZ for fault tolerance)
  max_size         = 4 # never go above 4 (cost protection)
  desired_capacity = 2 # start with 2

  launch_template {
    id = aws_launch_template.app_template.id

    # $Latest always uses the most recent version of the launch template.
    # If you create a new version (e.g., to update the app), the next
    # instance refresh will pick it up automatically.
    version = "$Latest"
  }
}

# The scaling policy: if average CPU across all instances goes above 50%,
# the ASG will launch new instances until it comes back down.
# When things quiet down, it will remove the extra instances.
resource "aws_autoscaling_policy" "cpu_tracking" {
  name                   = "cpu-tracking-policy"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    # Keep average CPU at or below 50%. AWS manages the scaling up and
    # down automatically — we just set the target and it does the math.
    target_value = 50.0
  }
}
