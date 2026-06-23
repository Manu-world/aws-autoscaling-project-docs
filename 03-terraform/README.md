# Project 1: Scalable Web App with Auto Scaling & ALB
## Terraform Edition

In [Part 1a](../01-aws-console/README.md) you clicked through every screen in the Console. In [Part 1b](../02-aws-cli/README.md) you scripted it step by step with the CLI. Now we build the exact same architecture a third time — using **Terraform**.

The difference is significant. Instead of a sequence of commands you have to run in the right order, you write a set of files that describe what you want AWS to look like. Terraform figures out what needs to be created, in what order, and handles all the wiring. When you want to tear it down, you run one command and everything is gone — cleanly, in the right order.

### Why Terraform?

| CLI | Terraform |
|---|---|
| You describe *how* to build — step by step | You describe *what* you want — Terraform builds it |
| Rebuilding requires re-running commands in the right order | `terraform apply` figures out the order and dependencies |
| Deleting requires many delete commands, carefully ordered | `terraform destroy` tears down everything in one shot |
| Hard to see what currently exists in AWS | `terraform state` always knows exactly what it built |
| Different scripts for staging vs production | Variables make environment differences trivial |

This is the industry standard. Most cloud engineering job descriptions list Terraform as a required or preferred skill. Once you understand the pattern here, you understand how it works everywhere.

---

## Prerequisites

- [ ] **Terraform installed** — follow the official guide at [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install). Pick your OS and follow the steps. When done, verify it worked:
  ```bash
  terraform -version
  # Should print something like: Terraform v1.9.0
  ```

- [ ] **AWS CLI installed and configured** — this was covered in [Part 1b Prerequisites](../02-aws-cli/README.md#prerequisites). Terraform uses the exact same credentials the AWS CLI uses, so if Part 1b worked, you are ready here too. Verify:
  ```bash
  aws sts get-caller-identity
  # Should return your account ID and IAM user — not an error
  ```

- [ ] **A key pair in AWS** — the name of the key pair you used in Part 1a or 1b (the name without `.pem`). If you need to create one, go to EC2 Console → Key Pairs → Create key pair, or run:
  ```bash
  aws ec2 create-key-pair --key-name playbook-key --query 'KeyMaterial' --output text > playbook-key.pem
  chmod 400 playbook-key.pem
  ```

- [ ] **Parts 1a and 1b completed** — you do not need to have running infrastructure, but you should understand what we are building. Terraform makes more sense when you already know what each piece does.

---

## Do You Need the S3 Backend?

One thing the Terraform community talks about a lot is "remote state." Let us break down what that actually means and whether you need it right now.

### What is state?

When Terraform deploys your infrastructure, it writes a file called `terraform.tfstate` into your project folder. This file is Terraform's memory — it records exactly what it created in AWS, with IDs and all. Without it, Terraform would not know what already exists and what needs to be changed or deleted.

### Local state (the default — fine for this tutorial)

By default, the state file just sits in your `03-terraform/` folder. You do not need to set anything up. This works perfectly fine for solo work and tutorials.

The `providers.tf` file in this folder has the S3 backend commented out. **Leave it as is and skip to the next section.** You will not notice any difference.

### S3 backend (for teams — set up later)

The problem with local state is sharing. If two engineers are deploying to the same AWS account from different laptops, they each have their own copy of the state file. They will overwrite each other's work.

The solution is to store the state file in an S3 bucket that everyone can access, and use a DynamoDB table as a lock so two people cannot deploy at exactly the same time.

When you are ready to set this up, create the bucket and lock table first (do this once):

```bash
# Create the S3 bucket (pick a globally unique name)
aws s3 mb s3://your-terraform-state-bucket --region us-east-1

# Enable versioning so you can recover from a corrupted state file
aws s3api put-bucket-versioning \
  --bucket your-terraform-state-bucket \
  --versioning-configuration Status=Enabled

# Create the DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then in `providers.tf`, uncomment the `backend "s3"` block and fill in your bucket name. Run `terraform init` again and Terraform will migrate your state to S3 automatically.

---

## The Files in This Folder

Here is what each file does before you read it:

**`providers.tf`** — Tells Terraform that we are using AWS and which version of the AWS provider plugin to download. Think of it as the import statement at the top of any code file.

**`variables.tf`** — All the values you might want to change: region, instance type, GitHub repo URL, key pair name. Instead of hunting through the code to update a value, you change it here (or pass it on the command line). This is also how you would reuse this same config for a staging environment with different settings.

**`user-data.sh`** — The same boot script from Part 1b, with one change: the GitHub URL is a placeholder (`${GITHUB_REPO}`) that Terraform fills in at deploy time from your variables. The script itself still does the same things: installs Node, builds your app, starts it with PM2.

**`main.tf`** — The main blueprint. All the actual AWS resources live here: security groups, launch template, target group, load balancer, auto scaling group, and scaling policy. It is the same architecture as Parts 1a and 1b — just written declaratively instead of imperatively.

**`outputs.tf`** — Tells Terraform what to print in your terminal after deploying. We print the load balancer DNS name so you know where your app is without going to the console.

---

## Step 1: Update Your Variables

Open `variables.tf`. There are four variables. The ones with `default` values work as-is. The one you must set is `key_pair_name`:

```bash
# Option A: pass it on the command line (no file change needed)
terraform apply -var="key_pair_name=playbook-key"

# Option B: create a terraform.tfvars file (gets picked up automatically)
echo 'key_pair_name = "playbook-key"' > terraform.tfvars
```

If you want to use your own GitHub repo instead of the default one, pass that too:

```bash
terraform apply \
  -var="key_pair_name=playbook-key" \
  -var="github_repo=https://github.com/YOUR_USERNAME/YOUR_REPO.git"
```

> **`terraform.tfvars` and the state file are in `.gitignore`** — do not commit them. The tfvars file may contain sensitive values and the state file contains resource IDs that should not be in version control.

---

## Step 2: MongoDB — Do You Need It?

Same answer as Parts 1a and 1b: no, you do not need it.

The default `user-data.sh` stores app data locally on each instance. With two instances behind the load balancer, you will see the split-brain behaviour (create a runbook, refresh several times, it appears and disappears). That is the expected behaviour without shared storage.

If you have a MongoDB Atlas account and want all instances to share data, open `user-data.sh` and uncomment the `MONGODB_URI` line near the bottom. Fill in your connection string. That is the only change needed — Terraform will pass it to every instance automatically.

---

## Step 3: The 3 Commands

Open a terminal inside this `03-terraform/` folder.

### `terraform init`

```bash
terraform init
```

This downloads the AWS provider plugin (the code that knows how to talk to AWS APIs) into a `.terraform/` folder. You only need to run this once, or again if you change the `required_providers` block.

You will see output like:

```
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
- Installing hashicorp/aws v5.x.x...
Terraform has been successfully initialized!
```

### `terraform plan`

```bash
terraform plan -var="key_pair_name=YOUR_KEY_NAME"
```

This is the safety check. Terraform reads your `.tf` files, compares them against the current state, and tells you exactly what it is going to create, change, or destroy — before touching anything in AWS.

Read through the output. You will see lines like:

```
+ resource "aws_security_group" "alb_sg" {     # + means "will be created"
+ resource "aws_lb" "app_alb" {
+ resource "aws_autoscaling_group" "app_asg" {
...
Plan: 10 to add, 0 to change, 0 to destroy.
```

Nothing has been created yet. This is your chance to review and catch mistakes.

### `terraform apply`

```bash
terraform apply -var="key_pair_name=YOUR_KEY_NAME"
```

Terraform will show the plan one more time and ask:

```
Do you want to perform these actions?
  Enter a value: yes
```

Type `yes` and press Enter. Terraform creates all 10 resources in the correct order — it automatically knows to create the ALB security group before the EC2 security group (because `ec2_sg` references `alb_sg.id`), the target group before the listener, and so on.

When it finishes (about 30 seconds for the AWS resources — then 3–5 more minutes for the instances to boot and build your app), you will see:

```
Apply complete! Resources: 10 added, 0 changed, 0 destroyed.

Outputs:

load_balancer_dns = "playbook-tf-alb-1234567890.us-east-1.elb.amazonaws.com"
```

Paste that DNS name into your browser. Your app is live.

> **Tip — skip the confirmation prompt:**
> ```bash
> terraform apply -var="key_pair_name=YOUR_KEY_NAME" -auto-approve
> ```
> Fine for solo use. In a team you usually want the confirmation prompt so someone reviews the plan before it runs.

---

## Step 4: Verify

After `terraform apply` finishes, wait 3–5 minutes for the EC2 instances to complete the boot script and build the Next.js app. Then:

1. Paste the `load_balancer_dns` output into your browser — you should see the app
2. Check instance health from the terminal:

```bash
# Get the target group ARN first
TG_ARN=$(aws elbv2 describe-target-groups \
  --names playbook-tf-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Check which instances are healthy
aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
  --output table
```

If instances show `unhealthy` after 5+ minutes, the same troubleshooting from Part 1b applies — SSH in, check `/var/log/user-data.log`.

---

## Step 5: Tear It Down

This is the moment where Terraform really shines compared to the CLI. Instead of carefully tracking ARNs and running eight delete commands in the right order, you run one command:

```bash
terraform destroy -var="key_pair_name=YOUR_KEY_NAME"
```

Terraform reads the state file, figures out the correct deletion order (reverse of creation), and removes everything. You will see the confirmation prompt again — type `yes`.

```
Destroy complete! Resources: 10 destroyed.
```

Compare that to the CLI cleanup section in Part 1b. Same result, one command.

---

## Troubleshooting

### "A load balancer cannot be attached to multiple subnets in the same Availability Zone"

**What happened:** The `data "aws_subnets" "public"` lookup returned more than one subnet in the same AZ. The ALB requires exactly one subnet per AZ.

**Why it happens:** If you have created extra subnets in your VPC for other projects (or if AWS created them during earlier tutorials), the filter returns all of them — including duplicates in the same zone.

**How it is fixed in `main.tf`:** The `locals` block after the data source uses a map expression to deduplicate subnets by AZ, keeping only one per zone. This was already applied — you do not need to do anything. If you were on an older version of the files, pull the latest `main.tf`.

---

### "Your requested instance type (t3.micro) is not supported in your requested Availability Zone (us-east-1e)"

**What happened:** The subnet lookup included a subnet in `us-east-1e`, which has limited instance type support. t3.micro is not available there.

**Why it happens:** `us-east-1e` is an older AZ that AWS added late and it does not support the full range of instance types. The default `aws_subnets` filter does not know about this.

**How it is fixed in `main.tf`:** The `locals` block explicitly excludes any subnet in `us-east-1e`. The ALB and ASG both use `local.unique_subnet_ids` instead of the raw subnet list. Already applied.

---

### Partially created resources from a failed apply

If `terraform apply` failed partway through, some resources were already created (you may have seen security groups and a target group succeed before the errors). That is fine — Terraform tracks what it created in the state file. After fixing `main.tf`, just run `terraform apply` again. Terraform will see what already exists, skip it, and only create what is missing.

---

## What You Proved

Over Parts 1a, 1b, and 1c you built the same production-quality architecture three times using three different tools:

- **Console** — built the mental model, understood every field
- **CLI** — turned it into reproducible commands, hit real-world problems and fixed them
- **Terraform** — described the desired state, let the tool handle the how

Each iteration got faster and more reliable. A senior engineer would reach for Terraform (or a similar IaC tool) for anything that runs in production. The Console and CLI are still essential for debugging and exploration — you need all three.

---

## Next Up

More projects coming in the series — IAM, RDS, CloudWatch, CI/CD pipelines, and beyond.
