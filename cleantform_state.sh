#!/bin/bash

# Root directory to start from (default: current directory)
ROOT_DIR="${1:-.}"

echo "Cleaning Terraform state files and .terraform directories in: $ROOT_DIR"

# Find and delete Terraform state files
find "$ROOT_DIR" -type f \( -name "*.tfstate" -o -name "*.tfstate.backup" \) -print -exec rm -f {} \;

# Find and delete .terraform directories
find "$ROOT_DIR" -type d -name ".terraform" -print -exec rm -rf {} \;

echo "Cleanup complete."
