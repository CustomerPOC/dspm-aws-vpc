#!/bin/bash

# Exit on any error
set -e

DIG_NAME="dig-securityuse1"
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

# Function to delete VPC and associated resources
cleanup_vpc_resources() {
    local region=$1
    echo "Cleaning up existing resources in region: $region"

    # Find VPCs with matching tag - force array output
    VPC_ID_OUTPUT=$(aws ec2 describe-vpcs --region $region \
        --filters "Name=tag:$TARGET_TAG_KEY,Values=$TARGET_TAG_VALUE" \
        --query "Vpcs[*].[VpcId][]" --output text | tr '\t' '\n')

    if [ -z "$VPC_ID_OUTPUT" ] || [ "$VPC_ID_OUTPUT" == "None" ]; then
        echo "No existing VPC found with tag $TARGET_TAG_KEY=$TARGET_TAG_VALUE in region $region"
        return 0
    fi

    # Process each VPC
    while read -r VPC_ID; do
        if [ -n "$VPC_ID" ]; then
            echo "Found VPC: $VPC_ID"

            # Delete NAT Gateways
            NAT_GW_OUTPUT=$(aws ec2 describe-nat-gateways --region $region \
                --filter "Name=vpc-id,Values=$VPC_ID" \
                --query "NatGateways[*].[NatGatewayId][]" --output text | tr '\t' '\n')

            while read -r NAT_GW; do
                if [ -n "$NAT_GW" ]; then
                    echo "Deleting NAT Gateway: $NAT_GW"
                    aws ec2 delete-nat-gateway --region $region --nat-gateway-id $NAT_GW
                    echo "Waiting for NAT Gateway deletion..."
                    aws ec2 wait nat-gateway-deleted --region $region --nat-gateway-id $NAT_GW
                fi
            done <<< "$NAT_GW_OUTPUT"

            # Delete VPC Endpoints
            VPC_ENDPOINT_OUTPUT=$(aws ec2 describe-vpc-endpoints --region $region \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query "VpcEndpoints[*].[VpcEndpointId][]" --output text | tr '\t' '\n')

            while read -r ENDPOINT; do
                if [ -n "$ENDPOINT" ]; then
                    echo "Deleting VPC Endpoint: $ENDPOINT"
                    aws ec2 delete-vpc-endpoints --region $region --vpc-endpoint-ids $ENDPOINT
                fi
            done <<< "$VPC_ENDPOINT_OUTPUT"

            # Delete Subnets
            SUBNET_OUTPUT=$(aws ec2 describe-subnets --region $region \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query "Subnets[*].[SubnetId][]" --output text | tr '\t' '\n')

            while read -r SUBNET; do
                if [ -n "$SUBNET" ]; then
                    echo "Deleting Subnet: $SUBNET"
                    aws ec2 delete-subnet --region $region --subnet-id $SUBNET
                fi
            done <<< "$SUBNET_OUTPUT"

            # Delete Route Tables (except main)
            ROUTE_TABLE_OUTPUT=$(aws ec2 describe-route-tables --region $region \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query "RouteTables[?Associations[0].Main != \`true\`].[RouteTableId][]" --output text | tr '\t' '\n')

            while read -r RT; do
                if [ -n "$RT" ]; then
                    echo "Deleting Route Table: $RT"
                    aws ec2 delete-route-table --region $region --route-table-id $RT
                fi
            done <<< "$ROUTE_TABLE_OUTPUT"

            # Detach and Delete Internet Gateways
            IGW_OUTPUT=$(aws ec2 describe-internet-gateways --region $region \
                --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
                --query "InternetGateways[*].[InternetGatewayId][]" --output text | tr '\t' '\n')

            while read -r IGW; do
                if [ -n "$IGW" ]; then
                    echo "Detaching Internet Gateway: $IGW"
                    aws ec2 detach-internet-gateway --region $region --internet-gateway-id $IGW --vpc-id $VPC_ID
                    echo "Deleting Internet Gateway: $IGW"
                    aws ec2 delete-internet-gateway --region $region --internet-gateway-id $IGW
                fi
            done <<< "$IGW_OUTPUT"

            # Delete Security Groups (except default)
            SG_OUTPUT=$(aws ec2 describe-security-groups --region $region \
                --filters "Name=vpc-id,Values=$VPC_ID" \
                --query "SecurityGroups[?GroupName != 'default'].[GroupId][]" --output text | tr '\t' '\n')

            while read -r SG; do
                if [ -n "$SG" ]; then
                    echo "Deleting Security Group: $SG"
                    aws ec2 delete-security-group --region $region --group-id $SG
                fi
            done <<< "$SG_OUTPUT"

            # Release Elastic IPs
            EIP_OUTPUT=$(aws ec2 describe-addresses --region $region \
                --filters "Name=domain,Values=vpc" \
                --query "Addresses[?AssociationId==null].[AllocationId][]" --output text | tr '\t' '\n')

            while read -r EIP; do
                if [ -n "$EIP" ]; then
                    echo "Releasing Elastic IP: $EIP"
                    aws ec2 release-address --region $region --allocation-id $EIP
                fi
            done <<< "$EIP_OUTPUT"

            # Finally, delete the VPC
            echo "Deleting VPC: $VPC_ID"
            aws ec2 delete-vpc --region $region --vpc-id $VPC_ID
        fi
    done <<< "$VPC_ID_OUTPUT"

    echo "Cleanup completed for region $region"
}

# Add this before the main VPC creation loop
tail -n +2 "$CSV_FILE" | grep -v '^[[:space:]]*$' | while read -r region cidr private_subnet public_subnet; do
    echo "Starting cleanup for region: $region"
    cleanup_vpc_resources "$region"
done

echo "Cleanup completed. Starting VPC creation..."

# Skip the first line (header)
tail -n +2 "$CSV_FILE" | grep -v '^[[:space:]]*$' | while read -r region cidr private_subnet public_subnet; do
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
        Key=Name,Value=$DIG_NAME \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    # Enable DNS hostnames and support
    aws ec2 modify-vpc-attribute --region $region --vpc-id $VPC_ID --enable-dns-hostnames
    aws ec2 modify-vpc-attribute --region $region --vpc-id $VPC_ID --enable-dns-support

    # Create Internet Gateway
    echo "Creating Internet Gateway"
    IGW_ID=$(aws ec2 create-internet-gateway --region $region --query 'InternetGateway.InternetGatewayId' --output text)
    aws ec2 create-tags --region $region --resources $IGW_ID --tags \
        Key=Name,Value=$DIG_NAME \
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
        Key=Name,Value=$DIG_NAME \
        Key=$TARGET_TAG_KEY,Value=$TARGET_TAG_VALUE

    echo "Successfully created VPC and all components in region $region"
done