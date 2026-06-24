# AWS Cloud Infrastructure Series

This series teaches you how to deploy a real web application on AWS — and then how to do it again, faster and more reliably, with less clicking each time.

We start by building everything manually through the AWS Console so you can see exactly what each piece is and why it exists. Then we tear it down and rebuild the same architecture using the AWS CLI, and then again using Terraform. By the end, you will understand not just how to click through a wizard, but what is actually happening inside AWS and how professionals manage it in the real world.

---

## The Series

| # | Guide | What you learn |
|---|-------|----------------|
| 1a | [Project 1 — Console Edition](01-aws-console/README.md) | Deploy a scalable web app manually via the AWS Console |
| 1b | [Project 1 — CLI Edition](02-aws-cli/README.md) | Rebuild the same architecture using the AWS CLI |
| 1c | [Project 1 — Terraform Edition](03-terraform/README.md) | Rebuild it again using Infrastructure as Code |

---

## Architecture

The infrastructure you will build across all three editions:

![AWS Auto Scaling Architecture — ALB, Auto Scaling Group across two Availability Zones](./architecture.png)

> **What this shows:** An internet-facing Application Load Balancer sitting in front of an Auto Scaling Group that spans two Availability Zones. Each EC2 instance is locked behind a security group that only accepts traffic from the ALB — never directly from the internet. On boot, each instance independently clones and starts the app via a user-data script.

---

## The Mental Model: Think of it as a Restaurant

Before touching the AWS Console, read this once. Every time you get confused about what a service does, come back here.

| AWS Service | The Restaurant Analogy |
|---|---|
| **Internet / Users** | Customers arriving at the restaurant wanting to be served |
| **Application Load Balancer (ALB)** | The host at the front door — greets customers and directs them to an available waiter so no single waiter gets overwhelmed |
| **EC2 Instances** | The waiters — they do the actual work of serving your application to users |
| **Auto Scaling Group (ASG)** | The manager — watches the floor; if waiters are overwhelmed, hires more instantly; when it's quiet, sends some home to save on payroll |
| **Security Groups** | The bouncers — control exactly who is allowed to talk to whom (customers talk to the host; only the host talks to the waiters) |
| **Launch Template** | The waiter training manual — when the manager hires a new waiter, this manual tells them exactly what to install and how to serve the app |

This is not just a metaphor. The security rules we set up will literally enforce: customers → ALB only, ALB → EC2 only. If you try to reach an EC2 instance directly from the internet, the bouncer blocks you.

---

## The Companion App

We use [**Ops Playbook Hub**](https://github.com/Manu-world/ops-playbook-hub) — a collaborative runbook manager where teams write and version their "how we do things" guides — as the application we deploy throughout this series.

You have three options. Pick whichever suits you:

**Option 1 — Use the public repo directly (recommended if you just want to follow along)**

```bash
git clone https://github.com/Manu-world/ops-playbook-hub.git
```

The repo is public. You do not need a GitHub account. Just clone it onto your EC2 instance and you are done.

**Option 2 — Fork it to your own GitHub account**

Go to [github.com/Manu-world/ops-playbook-hub](https://github.com/Manu-world/ops-playbook-hub), click Fork, and use your own URL in the user-data script. This way the repo is yours to keep and modify.

**Option 3 — Use your own existing project**

If you already have a Node.js application, you can follow along with that instead. The only requirement is that your app listens on port 3000 and has a `GET /api/health` endpoint that returns HTTP 200. Everything else in this series applies equally.

> You are going to tear all of this infrastructure down after the tutorial anyway, so do not overthink the choice. The app is just something to deploy — the real lesson is the cloud infrastructure around it.

---

## Do You Need MongoDB?

Short answer: **no, you do not need it to follow this tutorial.**

Here is what actually happens with and without it:

### Without MongoDB (the default — no setup needed)

The app stores its data in a local file on each EC2 instance's disk. You do not need to configure anything. It works.

The catch is this: when you scale to two or more instances behind the Load Balancer, each instance has its own copy of the data. Create a runbook, then refresh the page several times — sometimes you will see it, sometimes you will not, depending on which instance the ALB sends you to. This is called the **split-brain problem**, and it is a real issue in distributed systems.

This is actually a great learning moment. See it live, understand why it happens, then decide whether you want to fix it.

### With MongoDB Atlas (optional — free tier available)

If you have a [MongoDB Atlas](https://www.mongodb.com/atlas) account, add your connection string to the user-data script:

```bash
echo 'MONGODB_URI="mongodb+srv://USER:PASS@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority"' \
  > /home/ec2-user/app/.env.local
```

All instances will now share the same database. The split-brain problem disappears. The app becomes truly stateless — any instance can handle any request, which is exactly what Auto Scaling needs to work correctly.

**If you are just here to learn the AWS concepts and will tear this down after taking your screenshots, skip MongoDB entirely.** The tutorial works perfectly without it.

---

## Prerequisites (for all editions)

- An AWS account
- Log in as an **IAM user with Administrator access** — do not use your root account
- A basic understanding of what a web server is (you do not need to know AWS at all)
