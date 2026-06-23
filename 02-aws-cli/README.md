at# Project 1: Scalable Web App with Auto Scaling & ALB
## CLI Edition

In [Part 1a — Console Edition](../01-aws-console/README.md) you built this entire architecture by clicking through the AWS Console. You saw every field, every screen, and every option. That was intentional — the console is the best way to build a mental model.

Now we are going to build the exact same thing again. Zero clicking. Every resource is a shell command.

### Why the CLI?

| Console | CLI |
|---|---|
| Easy to explore, hard to repeat | Every resource is a reproducible command |
| Settings live inside AWS — invisible to your team | Commands live in files — reviewable, version-controlled, shareable |
| Rebuilding takes an hour of clicking | One script, one run, done |
| Mistakes are hard to trace | Every action is logged and auditable |
| Not scriptable | Runs in CI/CD, automation, and cron |

In a professional environment, nobody provisions infrastructure by clicking through a wizard. The CLI is how it is actually done — and Terraform (Part 1c) takes it one step further.

---

## Prerequisites

- [ ] **AWS CLI installed** → [Installation guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [ ] **AWS CLI configured** with your IAM user credentials:
  ```bash
  aws configure
  # AWS Access Key ID:     (your IAM user access key)
  # AWS Secret Access Key: (your IAM user secret)
  # Default region name:   us-east-1
  # Default output format: json
  ```
- [ ] **Verify it works:**
  ```bash
  aws sts get-caller-identity
  # You should see your account ID and IAM user ARN — not an error
  ```
- [ ] **A key pair** already created in AWS (you need its name — not the `.pem` file — for the launch template)

> Everything in this guide runs in a single terminal session. We store IDs in shell variables so later commands can reference them automatically. **Do not close your terminal mid-way through.** If you do, the variables will be gone and you will need to look up the IDs manually using `aws ec2 describe-...` commands.

---

## Step 0: Discover Your Network (VPC & Subnets)

Before creating anything, we need to know which network to put it in. We will store the IDs in shell variables so every command that follows can use them automatically.

```bash
# Get your Default VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" --output text)
echo "Using VPC: $VPC_ID"

# Get two subnet IDs from different Availability Zones
SUBNET_1=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values=$VPC_ID \
    --query "Subnets[0].SubnetId" --output text)

SUBNET_2=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values=$VPC_ID \
    --query "Subnets[1].SubnetId" --output text)

echo "Using Subnets: $SUBNET_1 and $SUBNET_2"
```

You should see output like:
```
Using VPC: vpc-0e61a6da59f5eae53
Using Subnets: subnet-0ae08e9e7cbb45335 and subnet-0140cab42a83e2901
```

> **Why two subnets in different AZs?** The Load Balancer requires at least two Availability Zones for high availability. If one AWS data centre goes down, traffic automatically flows through the other.

---

## Step 1: Security Groups — The Bouncers

We need two security groups. The same rule from the Console edition applies here: EC2 instances must never be reachable directly from the internet. Only the ALB gets in.

```bash
# 1. Create the ALB Security Group (allows public HTTP traffic)
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name playbook-alb-cli-sg \
    --description "Allow public HTTP traffic" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp --port 80 --cidr 0.0.0.0/0

echo "ALB Security Group: $ALB_SG_ID"

# 2. Create the EC2 Security Group (allows traffic ONLY from the ALB)
EC2_SG_ID=$(aws ec2 create-security-group \
    --group-name playbook-ec2-cli-sg \
    --description "Allow traffic from ALB only" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $EC2_SG_ID \
    --protocol tcp --port 3000 \
    --source-group $ALB_SG_ID

echo "EC2 Security Group: $EC2_SG_ID"
```

Notice the source for the EC2 rule: `--source-group $ALB_SG_ID`. We are not allowing a CIDR range (like `10.0.0.0/8`). We are saying "only traffic from resources inside this specific security group" — which is the ALB. This is the correct production pattern.

---

## Step 2: The User-Data Script — The Deployment Blueprint

Before creating the launch template, we need the script that will run on each new instance when it boots. This is the `user-data.sh` file already in this directory.

Look at it:

```bash
cat user-data.sh
```

A few things worth noticing:

- `set -xe` — if any command fails, the script immediately stops and logs what went wrong. Without this, failures are silent and debugging becomes a nightmare.
- `exec > /var/log/user-data.log 2>&1` — every line of output is saved to a log file. When an instance is unhealthy and you SSH in, this file tells you exactly what went wrong.
- The swap block — `next build` requires more memory than a t3.micro has. Without swap, it gets silently killed mid-build and the app never starts.
- PM2 `startup` + `save` — this makes the app survive instance reboots.
- The MongoDB comment — if you have Atlas, uncomment that line. If not, leave it. Both paths work.

---

## Step 3: Launch Template — The Training Manual

The launch template tells the Auto Scaling Group exactly how to set up every new instance: which OS image, which instance type, which security group, and what to run on boot.

The CLI does not have a file-picker for the user-data script. It must be **base64-encoded** and embedded in the JSON. This command handles that automatically with shell substitution:

```bash
aws ec2 create-launch-template \
    --launch-template-name playbook-cli-template \
    --version-description "v1" \
    --launch-template-data '{
        "ImageId": "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64",
        "InstanceType": "t3.micro",
        "KeyName": "YOUR_KEY_PAIR_NAME",
        "SecurityGroupIds": ["'"$EC2_SG_ID"'"],
        "UserData": "'"$(base64 user-data.sh | tr -d '\n')"'"
    }'
```

Replace `YOUR_KEY_PAIR_NAME` with the name of your key pair exactly as it appears in the AWS Console — without the `.pem` extension. For example, if your file is `playbook-key.pem`, use `playbook-key`.

> **Why `resolve:ssm:...` instead of an AMI ID like `ami-0abcd1234`?**
>
> A hardcoded AMI ID goes stale. The SSM parameter path always resolves to the latest security-patched version of Amazon Linux 2023 automatically. Every new instance gets the freshest OS without you having to manually update the template. This is the correct production approach.
>
> There is one quirk this introduces, which we cover in the Troubleshooting section.

---

## Step 4: Target Group & Application Load Balancer

Three commands. First the target group (where traffic goes), then the load balancer itself (the public entry point), then the listener that connects them.

```bash
# 1. Create the Target Group
#    This is where the ALB sends traffic — port 3000 is where our app listens
TG_ARN=$(aws elbv2 create-target-group \
    --name playbook-cli-tg \
    --protocol HTTP --port 3000 \
    --vpc-id $VPC_ID \
    --health-check-path "/api/health" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)

echo "Target Group: $TG_ARN"

# 2. Create the Load Balancer (internet-facing, across two AZs)
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name playbook-cli-alb \
    --subnets $SUBNET_1 $SUBNET_2 \
    --security-groups $ALB_SG_ID \
    --scheme internet-facing \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)

echo "ALB: $ALB_ARN"

# 3. Connect them via a Listener (port 80 on the ALB → port 3000 on the instances)
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN
```

> **Health check path: `/api/health` — not `/api/health/`**
>
> The trailing slash matters. With a trailing slash, Next.js returns a `308 Redirect`, not a `200 OK`. The ALB does not follow redirects during health checks, so the instance gets marked unhealthy even when the app is working perfectly. Always use the exact path without a trailing slash.

---

## Step 5: Auto Scaling Group — The Manager

This ties everything together. The ASG manages how many instances are running, places them across both subnets, attaches them to the load balancer, and scales based on CPU load.

```bash
# 1. Create the Auto Scaling Group
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name playbook-cli-asg \
    --launch-template LaunchTemplateName=playbook-cli-template,Version=1 \
    --min-size 2 \
    --max-size 4 \
    --desired-capacity 2 \
    --vpc-zone-identifier "$SUBNET_1,$SUBNET_2" \
    --target-group-arns $TG_ARN \
    --health-check-type ELB \
    --health-check-grace-period 300

# 2. Add a CPU-based scaling policy
aws autoscaling put-scaling-policy \
    --auto-scaling-group-name playbook-cli-asg \
    --policy-name cpu-tracking-policy \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ASGAverageCPUUtilization"
        },
        "TargetValue": 50.0
    }'
```

Two things worth understanding here:

**`--health-check-type ELB`** — This is important. By default, the ASG uses its own EC2 health check (is the machine on?). Setting this to `ELB` means the ASG trusts the Load Balancer's opinion: if the ALB marks an instance unhealthy (no `200` from `/api/health`), the ASG will terminate it and launch a fresh replacement. This is what gives you self-healing behaviour.

**`--health-check-grace-period 300`** — New instances need time to boot, install Node.js, and build the app. This tells the ASG to wait 5 minutes before it starts checking health. Without this, the ASG will terminate an instance that is still booting.

---

## Step 6: Verify

Wait 3–5 minutes for the instances to boot and complete the user-data script, then verify:

```bash
# Get the public DNS name of your load balancer
aws elbv2 describe-load-balancers \
    --load-balancer-arns $ALB_ARN \
    --query 'LoadBalancers[0].DNSName' --output text
```

You will get something like:
```
playbook-cli-alb-1353886366.us-east-1.elb.amazonaws.com
```

Paste that into your browser. You should see the app.

To check instance health from the terminal:

```bash
aws elbv2 describe-target-health \
    --target-group-arn $TG_ARN \
    --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Description]' \
    --output table
```

You want to see `healthy` for all targets. If instances are `unhealthy`, go straight to the Troubleshooting section below — the answer is almost certainly there.

---

## Troubleshooting

This section documents the real issues encountered when building this guide. If your instances are cycling (spinning up, failing, draining, repeating), start here.

---

### Issue 1: Instances have no Public IP → app never starts → infinite draining loop

**Symptoms:**
- Instances keep spinning up, failing health checks, getting "Drained", and being replaced by new instances that also fail
- Some instances show a Public IP, others show none
- The instance that has a Public IP works; the others do not

**Root cause:**

When the ASG launches instances across two subnets, some AWS subnets have **auto-assign public IP** enabled and some do not. An instance without a public IP has no internet access. Without internet access, `user-data.sh` fails silently — it cannot `dnf update`, cannot download Node.js, cannot `git clone` the repo. Because the app never starts, `/api/health` never responds, and the ALB marks the instance unhealthy.

The ASG then terminates it and tries again with a new instance in the same broken subnet. This is the loop you see.

**Fix — force both subnets to assign public IPs:**

```bash
aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET_1 \
    --map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
    --subnet-id $SUBNET_2 \
    --map-public-ip-on-launch
```

After running these, the next batch of instances launched by the ASG will receive a public IP. Existing broken instances need to be replaced (see the "replace all instances" commands at the end of this section).

---

### Issue 2: Cannot SSH into instances — wrong or missing key pair

**Symptoms:**
- The connect dialog in the console shows a key pair name you do not recognise (e.g., `idr-something`)
- You cannot SSH in even to the instance that has a public IP

**Root cause:**

The AWS Console has a required dropdown for key pairs — you cannot accidentally skip it. The CLI has no such guardrail. If you do not pass `--key-name` in the launch template, AWS builds the instance with no SSH key attached and you have no way to get in.

**Fix — create a new launch template version with the key pair:**

You cannot edit an existing launch template version. You create a new version instead:

```bash
aws ec2 create-launch-template-version \
    --launch-template-name playbook-cli-template \
    --version-description "v2-added-ssh-key" \
    --source-version 1 \
    --launch-template-data '{
        "KeyName": "playbook-key"
    }'
```

Replace `playbook-key` with your actual key pair name (without `.pem`). The `--source-version 1` flag means version 2 inherits everything from version 1 and only overrides what you specify — you do not need to repeat the AMI, instance type, or user-data.

Then tell the ASG to use the new version:

```bash
aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name playbook-cli-asg \
    --launch-template LaunchTemplateName=playbook-cli-template,Version=2
```

> This guide includes `"KeyName": "YOUR_KEY_PAIR_NAME"` in the original Step 3 command to prevent this issue from the start. If you followed it, you will not hit this problem.

---

### Issue 3: ALB shows "reachability may be impacted" — missing internet gateway route

**Symptoms:**
- The ALB console shows a yellow warning: "Load balancer reachability may be impacted"
- Clicking the warning says: "Missing IPv4 internet gateway route required for public connectivity"
- Instances in one specific Availability Zone are always unhealthy, no matter how many times they are replaced

**Root cause:**

When we used `aws ec2 describe-subnets` to pick two subnets, the CLI picked whatever happened to be first and second in AWS's list. One of them may be a **private subnet** — a subnet with no route to the internet. Even if an instance gets a public IP, it has nowhere to route traffic out to download your app.

This happens when a VPC has been used for other purposes (e.g., an RDS database that was intentionally kept private) and has leftover private subnets mixed in with the public ones.

**How to check:**

Look at the subnet's route table. If there is no route with destination `0.0.0.0/0` pointing to an internet gateway, the subnet is private.

**Fix — add the internet gateway route to the affected subnet:**

```bash
# 1. Find the Internet Gateway attached to your VPC
IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters Name=attachment.vpc-id,Values=$VPC_ID \
    --query "InternetGateways[0].InternetGatewayId" \
    --output text)

echo "Internet Gateway: $IGW_ID"

# 2. Find the Route Table for the broken subnet (replace $SUBNET_2 with whichever is failing)
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters Name=association.subnet-id,Values=$SUBNET_2 \
    --query "RouteTables[0].RouteTableId" \
    --output text)

# If the subnet does not have its own route table, it inherits the VPC's main route table.
# This handles that case:
if [ "$ROUTE_TABLE_ID" == "None" ] || [ -z "$ROUTE_TABLE_ID" ]; then
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
        --filters Name=vpc-id,Values=$VPC_ID Name=association.main,Values=true \
        --query "RouteTables[0].RouteTableId" \
        --output text)
fi

echo "Route Table: $ROUTE_TABLE_ID"

# 3. Add the internet route
aws ec2 create-route \
    --route-table-id $ROUTE_TABLE_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $IGW_ID
```

Once this route exists, the ALB warning clears immediately. New instances launched into that subnet will have a working path to the internet.

---

### Issue 4: Instance refresh fails — "SSM parameter not supported when skip matching is enabled"

**Full error:**
```
The launch template for the Auto Scaling group isn't valid. A launch template
that uses an SSM parameter instead of an AMI ID for ImageId is not supported
when skip matching is enabled.
```

**Root cause:**

Our launch template uses `resolve:ssm:...` instead of a hardcoded AMI ID. This is a best practice — it always picks the latest patched OS. But Instance Refresh has a feature called "Skip matching" that compares the AMI ID of running instances against the launch template to decide which ones need replacing. When the template says "go ask SSM", the ASG cannot do that comparison and throws this error.

**Fix:**

Disable skip matching when starting the refresh:

```bash
aws autoscaling start-instance-refresh \
    --auto-scaling-group-name playbook-cli-asg \
    --preferences '{"SkipMatching": false}'
```

This forces the ASG to replace all instances without trying to compare AMI IDs.

---

### Alternative: Replace all instances by scaling to zero and back up

If instance refresh is giving you trouble, this approach always works. Scale the ASG to zero (kills all instances), wait for them to terminate, then scale back up (spawns fresh instances with the latest config). Simple and reliable.

```bash
# Step 1: Scale down to zero (terminates all running instances)
aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name playbook-cli-asg \
    --desired-capacity 0 \
    --min-size 0

echo "Waiting for instances to terminate... check the console."
```

Wait 2–3 minutes for all instances to terminate (you can watch in the EC2 Instances console).

```bash
# Step 2: Scale back up (launches fresh instances with the current config)
aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name playbook-cli-asg \
    --desired-capacity 2 \
    --min-size 2
```

The new instances will boot with the correct subnet settings, key pair, and user-data and should become healthy within 5 minutes.

---

## Cleanup — Tear It All Down

Always delete resources in this order. Deleting in the wrong order will cause dependency errors.

```bash
# 1. Delete the Auto Scaling Group (this also terminates all EC2 instances)
aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name playbook-cli-asg \
    --force-delete

# 2. Delete the Load Balancer
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN

# Wait ~30 seconds for the ALB to finish deleting before removing the listener/TG
sleep 30

# 3. Delete the Target Group
aws elbv2 delete-target-group --target-group-arn $TG_ARN

# 4. Delete the Launch Template
aws ec2 delete-launch-template \
    --launch-template-name playbook-cli-template

# 5. Delete Security Groups (EC2 first, then ALB — because EC2 SG references ALB SG)
aws ec2 delete-security-group --group-id $EC2_SG_ID
aws ec2 delete-security-group --group-id $ALB_SG_ID

echo "All resources deleted."
```

> If any delete command fails with a dependency error, wait 30–60 seconds and try again. AWS sometimes takes a moment to fully release resources.

---

## What You Proved

You built the exact same production-quality architecture as Part 1a — high availability, self-healing, elastic scaling, security group isolation — but this time with commands you can save in a file, put in version control, and re-run on any machine in under 10 minutes.

Every problem you hit along the way (missing public IPs, no SSH key, private subnet routing, instance refresh quirks) is a real issue engineers encounter in production. You now know why they happen and exactly how to fix them.

---

## Next Up

[Part 1c — Terraform Edition](../03-terraform/README.md)

We will build this a third time using Terraform. Instead of a sequence of commands, the entire infrastructure is declared in configuration files. One command — `terraform apply` — provisions everything. One command — `terraform destroy` — tears it all down.
