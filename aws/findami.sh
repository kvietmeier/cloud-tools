AMI_ID="ami-1234567890abcdef0"
REGION_FILE="regions.txt"

while IFS= read -r region; do
  [[ -z "$region" || "$region" =~ ^# ]] && continue

  result=$(aws ec2 describe-images \
    --image-ids "$AMI_ID" \
    --region "$region" \
    --query 'Images[0].ImageId' \
    --output text 2>&1)

  if [[ "$result" == "$AMI_ID" ]]; then
    echo "✅ $region: FOUND"
  elif echo "$result" | grep -q "InvalidAMIID.NotFound"; then
    echo "❌ $region: Not Found"
  else
    echo "⚠️  $region: Error ($result)"
  fi
done < "$REGION_FILE"