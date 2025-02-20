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
    }

    # Get VPC ID and verify it exists
    VPC_ID=$(aws ec2 describe-vpcs --region $region --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].VpcId" --output text)
    if [ -z "$VPC_ID" ]; then
        echo "Error: No VPC found with tag $TARGET_TAG_KEY=$TARGET_TAG_VALUE in region $region"
        continue
    fi

    VPC_CIDR_BLOCKS=$(aws ec2 describe-vpcs --region $region --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" --query "Vpcs[*].CidrBlockAssociationSet[*].CidrBlock" --output text)

    # Add the new CIDR block to the VPC
    echo "Adding CIDR block $cidr to VPC $VPC_ID"
    if ! aws ec2 associate-vpc-cidr-block --region $region --vpc-id $VPC_ID --cidr-block $cidr; then
        echo "Error: Failed to associate CIDR block $cidr with VPC $VPC_ID"
        continue
    fi

    # Get subnet IDs and verify they exist
    PUBLIC_SUBNET_ORIGINAL=$(aws ec2 describe-subnets --region $region --filters "Name=tag:Name,Values=dig-security-publicuse1" --query 'Subnets[*].SubnetId' --output text)
    if [ -z "$PUBLIC_SUBNET_ORIGINAL" ]; then
        echo "Error: Original public subnet not found in region $region"
        continue
    fi

    PRIVATE_SUBNET_ORIGINAL=$(aws ec2 describe-subnets --region $region --filters "Name=tag:Name,Values=dig-security-privateuse1" --query 'Subnets[*].SubnetId' --output text)
    if [ -z "$PRIVATE_SUBNET_ORIGINAL" ]; then
        echo "Error: Original private subnet not found in region $region"
        continue
    fi

    # Get route tables and verify they exist
    PUBLIC_ROUTE_TABLE=$(aws ec2 describe-route-tables --region $region --filters "Name=association.subnet-id,Values=$PUBLIC_SUBNET_ORIGINAL" --query "RouteTables[*].RouteTableId" --output text)
    if [ -z "$PUBLIC_ROUTE_TABLE" ]; then
        echo "Error: Public route table not found for subnet $PUBLIC_SUBNET_ORIGINAL"
        continue
    fi

    PRIVATE_ROUTE_TABLE=$(aws ec2 describe-route-tables --region $region --filters "Name=association.subnet-id,Values=$PRIVATE_SUBNET_ORIGINAL" --query "RouteTables[*].RouteTableId" --output text)
    if [ -z "$PRIVATE_ROUTE_TABLE" ]; then
        echo "Error: Private route table not found for subnet $PRIVATE_SUBNET_ORIGINAL"
        continue
    fi

    # Create new subnets with error handling
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

    # Remove old CIDR blocks
    for existing_cidr in $VPC_CIDR_BLOCKS; do
        if [ "$existing_cidr" != "$cidr" ]; then
            echo "Removing CIDR block: $existing_cidr"
            ASSOCIATION_ID=$(aws ec2 describe-vpcs --region $region --vpc-id $VPC_ID --query "Vpcs[0].CidrBlockAssociationSet[?CidrBlock=='$existing_cidr'].AssociationId" --output text)
            if [ -n "$ASSOCIATION_ID" ]; then
                aws ec2 disassociate-vpc-cidr-block --region $region --association-id $ASSOCIATION_ID
            else
                echo "Warning: Could not find association ID for CIDR block $existing_cidr"
            fi
        fi
    done

    # Delete old subnets
    echo "Deleting original public subnet"
    aws ec2 delete-subnet --region $region --subnet-id $PUBLIC_SUBNET_ORIGINAL || echo "Warning: Failed to delete original public subnet"
    
    echo "Deleting original private subnet"
    aws ec2 delete-subnet --region $region --subnet-id $PRIVATE_SUBNET_ORIGINAL || echo "Warning: Failed to delete original private subnet"

    echo "Successfully processed region $region"
done

echo "Script execution completed for all specified regions."