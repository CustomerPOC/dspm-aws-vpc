#!/bin/bash

# Exit on any error
set -e

TARGET_TAG_KEY="dig-security"
TARGET_TAG_VALUE="true"
CSV_FILE="example.csv"
IFS=","

# Function to handle errors
handle_error() {
    echo "Error occurred in line $1"
    echo "Error message: $2"
    exit 1
}

# Set up error trap
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    echo "Error: CSV file '$CSV_FILE' not found"
    exit 1
fi

# Skip the first line (header)
tail -n +2 "$CSV_FILE" | while read -r region cidr private_subnet public_subnet; do
    echo "Processing Region: $region"

    # Verify all required variables are set
    if [ -z "$region" ] || [ -z "$cidr" ] || [ -z "$private_subnet" ] || [ -z "$public_subnet" ]; then
        echo "Error: Missing required parameters for region $region"
        continue
    fi

    # Create VPC
    echo "Creating VPC with CIDR $cidr"
    VPC_ID=$(aws ec2 create-vpc --region $region --cidr-block $cidr --query 'Vpc.VpcId' --output text)
    aws ec2 create-tags --region $region --resources $VPC_ID --tags \
        Key=Name,Value="dig-security" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    # Enable DNS hostnames and support
    aws ec2 modify-vpc-attribute --region $region --vpc-id $VPC_ID --enable-dns-hostnames
    aws ec2 modify-vpc-attribute --region $region --vpc-id $VPC_ID --enable-dns-support

    # Create Internet Gateway
    echo "Creating Internet Gateway"
    IGW_ID=$(aws ec2 create-internet-gateway --region $region --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 create-tags --region $region --resources $IGW_ID --tags \
        Key=Name,Value="dig-security" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE
    aws ec2 attach-internet-gateway --region $region --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

    # Get first AZ in region
    AZ=$(aws ec2 describe-availability-zones --region $region --query 'AvailabilityZones[0].ZoneName' --output text)

    # Create public subnet
    echo "Creating public subnet with CIDR $public_subnet"
    PUBLIC_SUBNET_ID=$(aws ec2 create-subnet --region $region --vpc-id $VPC_ID --cidr-block $public_subnet --availability-zone $AZ --query 'Subnet.SubnetId' --output text)
    aws ec2 create-tags --region $region --resources $PUBLIC_SUBNET_ID --tags \
        Key=Name,Value="dig-security-publicuse1" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    # Enable auto-assign public IP for public subnet
    aws ec2 modify-subnet-attribute --region $region --subnet-id $PUBLIC_SUBNET_ID --map-public-ip-on-launch

    # Create private subnet
    echo "Creating private subnet with CIDR $private_subnet"
    PRIVATE_SUBNET_ID=$(aws ec2 create-subnet --region $region --vpc-id $VPC_ID --cidr-block $private_subnet --availability-zone $AZ --query 'Subnet.SubnetId' --output text)
    aws ec2 create-tags --region $region --resources $PRIVATE_SUBNET_ID --tags \
        Key=Name,Value="dig-security-privateuse1" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    # Create public route table
    echo "Creating public route table"
    PUBLIC_RT_ID=$(aws ec2 create-route-table --region $region --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-tags --region $region --resources $PUBLIC_RT_ID --tags \
        Key=Name,Value="dig-security-publicuse1" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE
    
    # Add route to Internet Gateway
    aws ec2 create-route --region $region --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
    aws ec2 associate-route-table --region $region --route-table-id $PUBLIC_RT_ID --subnet-id $PUBLIC_SUBNET_ID

    # Create NAT Gateway
    echo "Creating NAT Gateway"
    EIP_ALLOC=$(aws ec2 allocate-address --region $region --domain vpc --query 'AllocationId' --output text)
    NAT_GW_ID=$(aws ec2 create-nat-gateway --region $region --subnet-id $PUBLIC_SUBNET_ID --allocation-id $EIP_ALLOC --query 'NatGateway.NatGatewayId' --output text)
    aws ec2 create-tags --region $region --resources $NAT_GW_ID --tags \
        Key=Name,Value="dig-securityuse1" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    # Wait for NAT Gateway to be available
    echo "Waiting for NAT Gateway to be available..."
    aws ec2 wait nat-gateway-available --region $region --nat-gateway-id $NAT_GW_ID

    # Create private route table
    echo "Creating private route table"
    PRIVATE_RT_ID=$(aws ec2 create-route-table --region $region --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
    aws ec2 create-tags --region $region --resources $PRIVATE_RT_ID --tags \
        Key=Name,Value="dig-security-privateuse1" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    # Add route to NAT Gateway
    aws ec2 create-route --region $region --route-table-id $PRIVATE_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID
    aws ec2 associate-route-table --region $region --route-table-id $PRIVATE_RT_ID --subnet-id $PRIVATE_SUBNET_ID

    # Create VPC Endpoint for S3
    echo "Creating S3 VPC Endpoint"
    S3_ENDPOINT=$(aws ec2 create-vpc-endpoint --region $region \
        --vpc-id $VPC_ID \
        --service-name "com.amazonaws.$region.s3" \
        --route-table-ids $PRIVATE_RT_ID \
        --query 'VpcEndpoint.VpcEndpointId' \
        --output text)
    aws ec2 create-tags --region $region --resources $S3_ENDPOINT --tags \
        Key=Name,Value="dig-security-s3" \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    echo "Successfully created VPC and all components in region $region"
done