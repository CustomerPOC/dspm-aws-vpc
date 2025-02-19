#!/bin/bash

TARGET_TAG_KEY="dig-security"
TARGET_TAG_VALUE="true"
CSV_FILE="example.csv"
IFS=","

# dig-security-privateuse1
# dig-security-publicuse1

# Skip the first line (header)
tail -n +2 "$CSV_FILE" | while read -r region cidr private_subnet public_subnet; do
    echo "Region: $region"

    VPC_ID=$(aws ec2 describe-vpcs --region $region --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].VpcId" --output text)
    
    aws ec2 associate-vpc-cidr-block --region $region --vpc-id $VPC_ID --cidr-block $cidr

    PUBLIC_SUBNET_CURRENT=$(aws ec2 describe-subnets --region $region --filters "Name=tag:Name, Values=dig-security-publicuse1" --query 'Subnets[*].SubnetId' --output text)
    PRIVATE_SUBNET_CURRENT=$(aws ec2 describe-subnets --region $region --filters "Name=tag:Name, Values=dig-security-privateuse1" --query 'Subnets[*].SubnetId' --output text)

    PRIVATE_ROUTE_TABLE=$(aws ec2 describe-route-tables --region $region --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_CURRENT" --query "RouteTables[*].RouteTableId" --output text)
    PUBLIC_ROUTE_TABLE=$(aws ec2 describe-route-tables --region $region --filters "Name=association.subnet-id,Values=$PUBLIC_SUBNET_CURRENT" --query "RouteTables[*].RouteTableId" --output text)
    
    # Create public subnet
    PUBLIC_SUBNET_NEW=$(aws ec2 create-subnet --region $region --vpc-id $VPC_ID --cidr-block $public_subnet --availability-zone $(aws ec2 describe-availability-zones --region $region --query 'AvailabilityZones[0].ZoneName' --output text) --query 'Subnet.SubnetId' --output text)
    # Tag the public subnet
    aws ec2 create-tags --region $region --resources $PUBLIC_SUBNET_NEW --tags Key=Name,Value="dig-security-publicuse1" Key=dig-security,Value=true
    # Associate the public subnet with the public route table
    aws ec2 associate-route-table --region $region --route-table-id $PUBLIC_ROUTE_TABLE --subnet-id $PUBLIC_SUBNET_NEW

    # Create private subnet
    PRIVATE_SUBNET_NEW=$(aws ec2 create-subnet --region $region --vpc-id $VPC_ID --cidr-block $private_subnet --availability-zone $(aws ec2 describe-availability-zones --region $region --query 'AvailabilityZones[0].ZoneName' --output text) --query 'Subnet.SubnetId' --output text)
    # Tag the private subnet
    aws ec2 create-tags --region $region --resources $PRIVATE_SUBNET_NEW --tags Key=Name,Value="dig-security-privateus1" Key=dig-security,Value=true
    # Associate the private subnet with the private route table
    aws ec2 associate-route-table --region $region --route-table-id $PRIVATE_ROUTE_TABLE --subnet-id $PRIVATE_SUBNET_NEW

done


# Define the new CIDR ranges
# NEW_VPC_CIDR="10.1.0.0/23"
# NEW_SUBNET1_CIDR="10.1.0.0/24"
# NEW_SUBNET2_CIDR="10.1.1.0/24"

# Define the list of regions to check
# REGIONS=("us-east-1" "us-west-1" "us-west-2" "us-east-2")  # Add or remove regions as needed

# List all VPCs with the specified tag value in all regions
# for REGION in "${REGIONS[@]}"; do
#     echo "Processing region: $REGION..."
    
#     VPC_IDS=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].VpcId" --output text)
#     echo "VPC IDs: $VPC_IDS"
# done

# for REGION in "${REGIONS[@]}"; do
#     echo "Processing region: $REGION..."
    
#     # List all VPCs with the specified tag value in the current region
#     VPC_IDS=$(aws ec2 describe-vpcs --region $REGION --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].VpcId" --output text)
    
#     for VPC_ID in $VPC_IDS; do
#         echo "Processing VPC: $VPC_ID in region: $REGION..."
        
#         # Add the new CIDR block to the VPC
#         aws ec2 associate-vpc-cidr-block --region $REGION --vpc-id $VPC_ID --cidr-block $NEW_VPC_CIDR

#         # Create new subnets within the new CIDR range
#         NEW_SUBNET1_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID --cidr-block $NEW_SUBNET1_CIDR --query "Subnet.SubnetId" --output text)
#         NEW_SUBNET2_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID --cidr-block $NEW_SUBNET2_CIDR --query "Subnet.SubnetId" --output text)
        
#         echo "Created Subnets: $NEW_SUBNET1_ID, $NEW_SUBNET2_ID in region: $REGION"
        
#         # Find and attach the appropriate route table
#         ROUTE_TABLE_ID=$(aws ec2 describe-route-tables --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query "RouteTables[0].RouteTableId" --output text)
#         aws ec2 associate-route-table --region $REGION --route-table-id $ROUTE_TABLE_ID --subnet-id $NEW_SUBNET1_ID
#         aws ec2 associate-route-table --region $REGION --route-table-id $ROUTE_TABLE_ID --subnet-id $NEW_SUBNET2_ID
        
#         echo "Associated new subnets with route table: $ROUTE_TABLE_ID in region: $REGION"

#         # Gather old subnet IDs to delete
#         OLD_SUBNET_IDS=$(aws ec2 describe-subnets --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.0.0/24,10.0.128.0/24" --query "Subnets[*].SubnetId" --output text)

#         for SUBNET_ID in $OLD_SUBNET_IDS; do
#             echo "Deleting old subnet: $SUBNET_ID in region: $REGION..."
#             aws ec2 delete-subnet --region $REGION --subnet-id $SUBNET_ID
#         done

#         # Disassociate the old CIDR block
#         aws ec2 disassociate-vpc-cidr-block --region $REGION --vpc-id $VPC_ID --cidr-block 10.0.0.0/16
#         echo "Disassociated old CIDR block from VPC: $VPC_ID in region: $REGION"
#     done
# done

echo "Script execution completed for all specified regions."