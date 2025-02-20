#!/bin/bash

# Exit on any error
set -e
set -x 

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

    PRIVATE_SUBNET_ORIGINAL=$(aws ec2 describe-subnets --region $region --filters "Name=tag:Name,Values=dig-security-privateuse1" --query 'Subnets[*].SubnetId' --output text)

    # Verify all required variables are set
    if [ -z "$region" ] || [ -z "$cidr" ] || [ -z "$private_subnet" ] || [ -z "$public_subnet" ]; then
        echo "Error: Missing required parameters for region $region"
        continue
    fi

    # Get VPC ID and verify it exists
    VPC_ID=$(aws ec2 describe-vpcs --region $region --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].VpcId" --output text)
    if [ -z "$VPC_ID" ]; then
        echo "Error: No VPC found with tag $TARGET_TAG_KEY=$TARGET_TAG_VALUE in region $region"
        continue
    fi

    VPC_CIDR_BLOCKS=$(aws ec2 describe-vpcs --region $region --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].CidrBlockAssociationSet[*].CidrBlock" --output text | tr -s '[:space:]')
    #VPC_CIDR_BLOCKS=$(aws ec2 describe-vpcs --region us-west-1 --filters "Name=tag:dig-security,Values=true" --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' --output text | tr '\t' '\n' | sort -u)
    
    echo $VPC_CIDR_BLOCKS
    # Add the new CIDR block to the VPC
    echo "Adding CIDR block $cidr to VPC $VPC_ID"
    ADD_CIDR="true"

    for existing_cidr in $VPC_CIDR_BLOCKS; do
        echo "Checking CIDR block: $existing_cidr"
        echo "CIDR block: $cidr"
  
        if [ "$existing_cidr" = "$cidr" ]; then
            ADD_CIDR="false"
            echo "CIDR block: $existing_cidr already exists, nothing to add"
            break
        fi
    done

    if [ "$ADD_CIDR" = "true" ]; then
        if ! aws ec2 associate-vpc-cidr-block --region $region --vpc-id $VPC_ID --cidr-block $cidr; then
            echo "Error: Failed to associate CIDR block $cidr with VPC $VPC_ID"
            continue
        fi
    fi

    # Get subnet IDs and verify they exist
    PUBLIC_SUBNET_ORIGINAL=$(aws ec2 describe-subnets --region $region --filters "Name=tag:Name,Values=dig-security-publicuse1" --query 'Subnets[*].SubnetId' --output text)
    if [ -z "$PUBLIC_SUBNET_ORIGINAL" ]; then
        echo "Error: Original public subnet not found in region $region"
    fi

    # Get route tables directly by tag name
    PUBLIC_ROUTE_TABLE=$(aws ec2 describe-route-tables --region $region --filters "Name=tag:Name,Values=dig-security-publicuse1" --query "RouteTables[*].RouteTableId" --output text)
    if [ -z "$PUBLIC_ROUTE_TABLE" ]; then
        echo "Error: Public route table not found with name dig-security-publicuse1"
        continue
    fi

    PRIVATE_ROUTE_TABLE=$(aws ec2 describe-route-tables --region $region --filters "Name=tag:Name,Values=dig-security-privateuse1" --query "RouteTables[*].RouteTableId" --output text)
    if [ -z "$PRIVATE_ROUTE_TABLE" ]; then
        echo "Error: Private route table not found with name dig-security-privateuse1"
        continue
    fi

    echo "Creating new public subnet"
    if ! PUBLIC_SUBNET_NEW=$(aws ec2 create-subnet --region $region --vpc-id $VPC_ID --cidr-block $public_subnet --availability-zone $(aws ec2 describe-availability-zones --region $region --query 'AvailabilityZones[0].ZoneName' --output text) --query 'Subnet.SubnetId' --output text); then
        echo "Error: Failed to create new public subnet"
        continue
    fi

    echo "Tagging new public subnet"
    aws ec2 create-tags --region $region --resources $PUBLIC_SUBNET_NEW --tags Key=Name,Value="dig-security-publicuse1" Key=dig-security,Value=true

    echo "Associating public subnet with route table"
    aws ec2 associate-route-table --region $region --route-table-id $PUBLIC_ROUTE_TABLE --subnet-id $PUBLIC_SUBNET_NEW

    echo "Creating new private subnet"
    if ! PRIVATE_SUBNET_NEW=$(aws ec2 create-subnet --region $region --vpc-id $VPC_ID --cidr-block $private_subnet --availability-zone $(aws ec2 describe-availability-zones --region $region --query 'AvailabilityZones[0].ZoneName' --output text) --query 'Subnet.SubnetId' --output text); then
        echo "Error: Failed to create new private subnet"
        continue
    fi

    echo "Tagging new private subnet"
    aws ec2 create-tags --region $region --resources $PRIVATE_SUBNET_NEW --tags Key=Name,Value="dig-security-privateuse1" Key=dig-security,Value=true

    echo "Associating private subnet with route table"
    aws ec2 associate-route-table --region $region --route-table-id $PRIVATE_ROUTE_TABLE --subnet-id $PRIVATE_SUBNET_NEW

    # Handle NAT Gateway and ENIs before deleting public subnet
    echo "Finding and deleting NAT Gateway in original public subnet"
    NAT_GW_ID=$(aws ec2 describe-nat-gateways --region $region --filter "Name=subnet-id,Values=$PUBLIC_SUBNET_ORIGINAL" --query 'NatGateways[0].NatGatewayId' --output text)
    if [ ! -z "$NAT_GW_ID" ] && [ "$NAT_GW_ID" != "None" ]; then
        echo "Deleting NAT Gateway: $NAT_GW_ID"
        aws ec2 delete-nat-gateway --region $region --nat-gateway-id $NAT_GW_ID
        
        # Wait for NAT Gateway to be deleted
        echo "Waiting for NAT Gateway to be deleted..."
        aws ec2 wait nat-gateway-deleted --region $region --nat-gateway-id $NAT_GW_ID
    fi

    # Create new NAT Gateway in new public subnet
    echo "Creating new NAT Gateway"
    EIP_ALLOC=$(aws ec2 allocate-address --region $region --domain vpc --query 'AllocationId' --output text)
    NEW_NAT_GW=$(aws ec2 create-nat-gateway --region $region --subnet-id $PUBLIC_SUBNET_NEW --allocation-id $EIP_ALLOC --query 'NatGateway.NatGatewayId' --output text)
    
    # Wait for NAT Gateway to be available
    echo "Waiting for new NAT Gateway to be available..."
    aws ec2 wait nat-gateway-available --region $region --nat-gateway-id $NEW_NAT_GW

    # Tag new NAT Gateway
    aws ec2 create-tags --region $region --resources $NEW_NAT_GW --tags Key=Name,Value="dig-securityuse1" Key=dig-security,Value=true

    # Delete old subnets (now safe to delete public subnet)
    echo "Deleting original public subnet"
    aws ec2 delete-subnet --region $region --subnet-id $PUBLIC_SUBNET_ORIGINAL || echo "Warning: Failed to delete original public subnet"
    

    if [ -z "$PRIVATE_SUBNET_ORIGINAL" ]; then
        echo "Info: Original private subnet not found in region $region nothing to delete"
    else
        echo "Deleting original private subnet"
        aws ec2 delete-subnet --region $region --subnet-id $PRIVATE_SUBNET_ORIGINAL || echo "Warning: Failed to delete original private subnet"
    fi
    
    # Remove old CIDR blocks
    for existing_cidr in $VPC_CIDR_BLOCKS; do
        if [ "$existing_cidr" != "$cidr" ]; then
            echo "Removing CIDR block: $existing_cidr"
            # the following arguments are required: --association-id
            aws ec2 delete-vpc-cidr-block --region $region --association-id $existing_cidr
            #aws ec2 disassociate-vpc-cidr-block --region $region --vpc-id $VPC_ID
        fi
    done

    echo "Successfully processed region $region"
done