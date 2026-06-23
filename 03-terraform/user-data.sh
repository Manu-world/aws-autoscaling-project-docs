#!/bin/bash
# ============================================================
# user-data.sh
#
# This script runs once automatically when each EC2 instance
# first boots. It installs everything the app needs and starts
# it running. PM2 keeps it alive after that.
#
# IMPORTANT — the ${GITHUB_REPO} placeholder below is NOT a
# bash variable. It is a Terraform template syntax. When you
# run `terraform apply`, Terraform reads this file, swaps in
# the actual GitHub URL from your variables, base64-encodes
# the whole thing, and passes it to AWS. By the time bash
# runs this script on the instance, it is a real URL.
#
# If you ever need to debug what happened during boot, SSH
# into the instance and run:
#   sudo cat /var/log/user-data.log
# Every line of output from this script is saved there.
# ============================================================

set -xe
exec > /var/log/user-data.log 2>&1

# Update the OS and install the tools we need
dnf update -y
dnf install -y git nodejs npm

# Add 1 GB of swap space so `next build` does not get OOM-killed
# on a t3.micro (which only has 1 GB of RAM). Without this, the
# build silently dies and the app never starts.
dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# PM2 is a process manager that keeps the app running if it crashes,
# and can restart it automatically after a server reboot.
npm install -g pm2@latest

# Clone the repo — ${GITHUB_REPO} gets replaced by Terraform at deploy
# time with the value from var.github_repo in variables.tf
git clone ${GITHUB_REPO} /home/ec2-user/app
cd /home/ec2-user/app

# ------------------------------------------------------------------
# Optional: MongoDB Atlas
#
# Without this, each instance stores data in a local file on its own
# disk. That works fine with one server. With two or more servers
# behind the load balancer, each instance has its own copy of the
# data — you might create a runbook and sometimes not see it because
# the ALB sent you to the other instance. This is the split-brain
# problem and it is a real distributed systems concept worth seeing.
#
# If you have a MongoDB Atlas account and want all instances to share
# data, uncomment the line below and fill in your connection string.
# ------------------------------------------------------------------
# echo 'MONGODB_URI="mongodb+srv://USER:PASS@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority"' > .env.local

# Install dependencies, build the production bundle, and start the app
npm install
npm run build
pm2 start npm --name "next-app" -- start

# These two lines make the app survive reboots. Without them, the app
# stops running if the instance restarts and never comes back on its own.
pm2 startup
pm2 save
