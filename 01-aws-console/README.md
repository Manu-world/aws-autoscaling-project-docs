# Project 1: Scalable Web App with Auto Scaling & ALB
## Console Edition

In this guide we are going to deploy a Next.js application on AWS — not on a single server hoping for the best, but behind a proper **Application Load Balancer** with an **Auto Scaling Group** that automatically adds servers when traffic spikes and removes them when it is quiet.

We are doing this through the AWS Console first, deliberately. Clicking through every screen and reading every option builds the visual mental model you need before we automate the same thing with the CLI and Terraform. Once you have done it by hand, the automated versions will make complete sense.

> **The architecture we are building:**
>
> ```
> Internet
>     │
>     ▼
> Application Load Balancer   (public-facing, port 80)
>     │
>     ├──▶ EC2 Instance #1    (your app, port 3000)
>     └──▶ EC2 Instance #2    (your app, port 3000)
>               │
>               ▼ (optional)
>         MongoDB Atlas        (shared data across all instances)
> ```

---

## Prerequisites

- AWS account, logged in as an IAM user with Administrator access (not root)
- Your app cloned from [github.com/Manu-world/ops-playbook-hub](https://github.com/Manu-world/ops-playbook-hub) or your own project
- Read the [series README](../../README.md) for the mental model and MongoDB guidance

---

## Step 1: Security First — The Bouncers (Security Groups)

We follow the **Principle of Least Privilege** from the very start. Our EC2 instances should never be reachable directly from the public internet — all traffic must go through the Load Balancer. We enforce this by creating two separate security groups and wiring them together.

**Navigate to:** EC2 Dashboard → Security Groups (under Network & Security)

### Create the ALB Security Group

This is the bouncer for the front door — it decides who can talk to the Load Balancer.

1. Click **Create security group**
2. Fill in:
   - **Security group name:** `nextjs-alb-sg`
   - **Description:** `Allow public HTTP traffic to the load balancer`
   - **VPC:** leave as your Default VPC
3. Under **Inbound rules**, click **Add rule:**
   - Type: `HTTP`
   - Port: `80`
   - Source: `Anywhere-IPv4` (`0.0.0.0/0`)
4. Click **Create security group**

### Create the EC2 Security Group

This bouncer only allows the ALB inside — nothing else from the internet reaches your servers directly.

1. Click **Create security group**
2. Fill in:
   - **Security group name:** `nextjs-ec2-sg`
   - **Description:** `Allow traffic only from the ALB`
   - **VPC:** leave as your Default VPC
3. Under **Inbound rules**, click **Add rule:**
   - Type: `Custom TCP`
   - Port: `3000` (the port our Next.js app listens on)
   - Source: click the search box and select **`nextjs-alb-sg`** (the security group you just created — not an IP address)
4. If you want SSH access for debugging, add a second rule:
   - Type: `SSH`
   - Port: `22`
   - Source: **My IP** (your specific IP only — never `0.0.0.0/0` for SSH)
5. Click **Create security group**

> **Why this matters:** By setting the EC2 source to the ALB's security group ID rather than an IP range, you are saying "only traffic that comes through this specific load balancer is allowed in." This is the proper production pattern.

---

## Step 2: The Training Manual — Launch Template

When the Auto Scaling Group needs to spin up a new server, it follows the Launch Template. Think of it as the waiter training manual — every new hire goes through the exact same setup so servers are identical and predictable.

**Navigate to:** EC2 Dashboard → Launch Templates → Create launch template

Fill in the following:

| Field | Value |
|---|---|
| **Launch template name** | `nextjs-app-template` |
| **Description** | `Template for Next.js web servers` |
| **AMI** | Amazon Linux 2023 (search for it — use the 64-bit x86 version) |
| **Instance type** | `t3.micro` (free-tier eligible; better network performance than t2) |
| **Key pair** | Select an existing key pair or create one (needed for SSH access) |
| **Subnet** | Do not include — the ASG will choose the subnet |
| **Security groups** | Select `nextjs-ec2-sg` |

### Advanced Details → User Data

Scroll to the very bottom of the page and find the **User data** field. This is a bash script that runs once when the instance first boots. It is your automated deployment script — the "training manual" being executed.

Paste the appropriate script from the two options below:

---

#### Option A — Without MongoDB (no database setup needed)

Use this if you are just following along and will tear this down after. The app works fine and data is stored locally on each instance.

```bash
#!/bin/bash
set -xe
exec > /var/log/user-data.log 2>&1

# Update system and install dependencies
dnf update -y
dnf install -y git nodejs npm

# Add swap space so `next build` does not get OOM-killed on t3.micro
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Install PM2 to keep the app running in the background
npm install -g pm2@latest

# Clone the repository
git clone https://github.com/Manu-world/ops-playbook-hub.git /home/ec2-user/app
cd /home/ec2-user/app

# Install packages and build the app
npm install
npm run build

# Start the app on port 3000
pm2 start npm --name "next-app" -- start
pm2 startup
pm2 save
```

---

#### Option B — With MongoDB Atlas (shared data across all instances)

Use this if you have a MongoDB Atlas account and want all instances to share the same data. Replace `YOUR_MONGODB_URI` with your actual connection string.

```bash
#!/bin/bash
set -xe
exec > /var/log/user-data.log 2>&1

# Update system and install dependencies
dnf update -y
dnf install -y git nodejs npm

# Add swap space so `next build` does not get OOM-killed on t3.micro
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Install PM2 to keep the app running in the background
npm install -g pm2@latest

# Clone the repository
git clone https://github.com/Manu-world/ops-playbook-hub.git /home/ec2-user/app
cd /home/ec2-user/app

# Connect to MongoDB Atlas (all instances will share the same data)
echo 'MONGODB_URI="YOUR_MONGODB_URI"' > .env.local

# Install packages and build the app
npm install
npm run build

# Start the app on port 3000
pm2 start npm --name "next-app" -- start
pm2 startup
pm2 save
```

---

> **Tip:** If you want to debug what happened during boot, SSH into the instance later and run:
> ```bash
> sudo cat /var/log/user-data.log
> ```
> Every command and its output is recorded there.

Click **Create launch template**.

---

## Step 3: The Host — Target Group & Application Load Balancer

The Load Balancer needs to know two things: where to send traffic (the Target Group) and how to check if a server is healthy enough to receive traffic (the health check). We set these up before creating the ALB itself.

### Create the Target Group

**Navigate to:** EC2 Dashboard → Target Groups → Create target group

| Field | Value |
|---|---|
| **Target type** | Instances |
| **Target group name** | `nextjs-tg` |
| **Protocol / Port** | HTTP / `3000` |
| **VPC** | Default VPC |

**Health check settings:**

| Field | Value | Why |
|---|---|---|
| **Protocol** | HTTP | |
| **Path** | `/api/health` | This endpoint returns HTTP 200 when the app is running correctly |

> **Important:** Use `/api/health` exactly — **no trailing slash**. If you use `/api/health/`, Next.js returns a 308 redirect, not a 200. The ALB does not follow redirects during health checks, so the instance will be marked unhealthy even when the app is running perfectly.
>
> The `/` root path also works as a fallback, but `/api/health` is more meaningful — it tells you the app's internal logic is working, not just that a web server is responding.

Click **Next**, skip the register targets screen (the ASG will do this automatically), and click **Create target group**.

### Create the Load Balancer

**Navigate to:** EC2 Dashboard → Load Balancers → Create load balancer → **Application Load Balancer**

| Field | Value |
|---|---|
| **Name** | `nextjs-alb` |
| **Scheme** | Internet-facing |
| **IP address type** | IPv4 |

**Network mapping:** Select your Default VPC, then check **at least two Availability Zones** (e.g., `us-east-1a` and `us-east-1b`). This is what makes your app survive a data centre failure — if one AZ goes down, the other keeps serving traffic.

**Security groups:** Remove the default group. Select `nextjs-alb-sg`.

**Listeners and routing:**
- Protocol: HTTP
- Port: 80
- Default action: Forward to `nextjs-tg`

Click **Create load balancer**.

---

## Step 4: The Manager — Auto Scaling Group

This is where everything comes together. The ASG is the manager that watches your servers, spawns new ones from the Launch Template when load goes up, and deregisters them from the Load Balancer when they are no longer needed.

**Navigate to:** EC2 Dashboard → Auto Scaling Groups → Create Auto Scaling group

**Step 1 — Name and template:**
- Name: `nextjs-asg`
- Launch template: `nextjs-app-template` (latest version)

**Step 2 — Network:**
- VPC: Default VPC
- Availability Zones: select the **same zones you chose for the ALB** (e.g., `us-east-1a` and `us-east-1b`)

**Step 3 — Load balancing:**
- Select **Attach to an existing load balancer**
- Choose **Choose from your load balancer target groups**
- Select `nextjs-tg`
- Turn on **ELB health checks** — this is important: it means the ASG trusts the ALB's opinion on instance health. If the ALB says an instance is unhealthy (not responding on `/api/health`), the ASG will automatically terminate it and launch a fresh replacement.

**Step 4 — Group size and scaling:**

| Setting | Value | Reason |
|---|---|---|
| **Desired capacity** | 2 | We always want 2 servers running |
| **Minimum capacity** | 2 | Never drop below 2 (one per AZ for fault tolerance) |
| **Maximum capacity** | 4 | Cap at 4 to control the bill |

**Scaling policy:**
- Type: Target tracking scaling policy
- Metric: Average CPU utilization
- Target value: `50%`

> When the average CPU across all instances exceeds 50%, the ASG launches more instances until the load spreads out. When it drops, it removes the extras. This is the elasticity that makes cloud infrastructure cost-effective.

> **MongoDB reminder:** You now have a Desired of 2, which means two EC2 instances will be running simultaneously. If you used Option A (no MongoDB), each instance has its own local data. Create a runbook through the Load Balancer URL, then refresh the page 10–15 times. You will notice it appears and disappears — the ALB is routing you to different instances and they do not share data. This is the split-brain problem in action. It is not a bug in the app — it is a fundamental property of stateful applications on stateless servers. Option B (MongoDB) solves it by giving all instances a single shared database.

Click through to **Review** and click **Create Auto Scaling group**.

---

## Step 5: Verification & The Chaos Test

Your instances need 3–5 minutes to boot, run the user-data script, install Node.js, build the Next.js app, and pass health checks. This is a good time to watch the Target Group health tab.

### Confirm the app is live

1. Go to **EC2 → Load Balancers** and select `nextjs-alb`
2. Copy the **DNS name** (something like `nextjs-alb-123456789.us-east-1.elb.amazonaws.com`)
3. Paste it into your browser

You should see the Ops Playbook Hub (or your own app). If you see a 502 Bad Gateway, the instances have not finished booting yet — wait another minute and refresh.

### Check health in the target group

Go to **EC2 → Target Groups → nextjs-tg → Targets tab**. You want to see all instances showing **Healthy** status. If any are **Unhealthy** after 5 minutes:

1. SSH into the instance: `ssh -i your-key.pem ec2-user@<instance-public-ip>`
2. Check what happened during boot: `sudo cat /var/log/user-data.log`
3. Check if the app is running: `curl -i http://localhost:3000/api/health`

### The Chaos Monkey Test — Prove the self-healing works

This is the part that makes cloud infrastructure impressive. Let's break something on purpose and watch AWS fix it.

1. Go to **EC2 → Instances**
2. Select one of the running instances that was created by your ASG
3. Click **Instance state → Terminate instance** and confirm

Now immediately switch to **Auto Scaling Groups → nextjs-asg → Activity tab**.

Within 60–90 seconds you will see an event appear: the ASG detected that the desired capacity dropped below 2 and launched a new replacement instance. The new instance will boot, run the user-data script, deploy your app, pass health checks, and be registered with the Load Balancer — automatically, with no intervention from you.

Your users never even noticed. That is **self-healing cloud infrastructure**.

> Take your screenshots now. Document what you built. Then tear it down: delete the ASG (which terminates the instances), the ALB, the Target Group, the Launch Template, and the Security Groups, in that order.

---

## What You Built

You just deployed a production-quality architecture:

- **High availability:** 2 instances across 2 Availability Zones — survives a data centre outage
- **Self-healing:** the ASG replaces unhealthy or terminated instances automatically
- **Elastic scaling:** CPU-triggered Auto Scaling adds capacity when you need it and removes it when you do not
- **Security:** EC2 instances are unreachable from the internet directly — all traffic flows through the ALB
- **Zero-downtime rolling:** when the ASG replaces instances, the ALB drains existing connections gracefully

---

## Next Up

Clicking through the Console is the best way to understand what each service does and why. But in a production environment, this is too slow and too error-prone — humans make mistakes, settings are invisible in screenshots, and you cannot version-control a series of mouse clicks.

In [Part 1b — CLI Edition](../02-cli/README.md), we will tear this down and build the exact same architecture using the AWS CLI, where every resource is a command you can save, review, and repeat.
