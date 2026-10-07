# Copyright 2026 Karl Vietmeier
# Licensed under the Apache License, Version 2.0

### --- Delete all of th default subnets in the default VPC.


# Get all subnets named "default"
$subnets = gcloud compute networks subnets list --filter="name=default" --format="value(name,region)"

# Loop through each subnet and delete it
foreach ($subnet in $subnets) {
    $splitSubnet = $subnet -split "\s+"  # Split name and region
    $name = $splitSubnet[0]
    $region = $splitSubnet[1]

    Write-Host "Deleting subnet: $name in region: $region"
    gcloud compute networks subnets delete $name --region=$region --quiet
}
