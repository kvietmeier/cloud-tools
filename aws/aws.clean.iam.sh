#!/usr/bin/bash

# =====================================================
# Script: aws-cli-reset-backup.sh
# Purpose: Safely reset AWS CLI credentials, config,
#          and SSO cache by backing up first.
# =====================================================

# Create a timestamp for backup
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME/.aws/bkup.$TIMESTAMP"

# Step 1: Check and back up existing AWS CLI credentials and config
echo "Checking AWS CLI config and credentials..."
mkdir -p "$BACKUP_DIR"

if [ -f ~/.aws/credentials ]; then
    cp ~/.aws/credentials "$BACKUP_DIR/credentials"
    echo "Backed up ~/.aws/credentials to $BACKUP_DIR/credentials"
else
    echo "No ~/.aws/credentials found"
fi

if [ -f ~/.aws/config ]; then
    cp ~/.aws/config "$BACKUP_DIR/config"
    echo "Backed up ~/.aws/config to $BACKUP_DIR/config"
else
    echo "No ~/.aws/config found"
fi

# Step 2: Check and back up AWS SSO cache
echo "Checking AWS SSO cache..."
if [ -d ~/.aws/sso/cache ]; then
    cp -r ~/.aws/sso/cache "$BACKUP_DIR/sso_cache"
    echo "Backed up SSO cache to $BACKUP_DIR/sso_cache"
else
    echo "No SSO cache found"
fi

# Step 3: Remove AWS CLI credentials, config, and SSO cache
rm -f ~/.aws/credentials
rm -f ~/.aws/config
rm -rf ~/.aws/sso/cache

# Step 4: Unset AWS-related environment variables
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
unset AWS_SECURITY_TOKEN
unset AWS_PROFILE
unset AWS_DEFAULT_PROFILE
unset AWS_SHARED_CREDENTIALS_FILE
unset AWS_CONFIG_FILE

# Step 5: Confirm reset is complete
echo "All AWS CLI credentials, environment variables, config, and SSO cache removed."
echo "Backup of original files saved at: $BACKUP_DIR"
echo "AWS CLI is now fully reset and ready for reconfiguration."
