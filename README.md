# VPC Recreation Script

## Overview
This script automates the process of recreating AWS VPC infrastructure across multiple regions. It first cleans up existing resources and then creates new ones. The script performs the following operations:
- Deletes existing VPCs and associated resources (cleanup phase)
- Creates new VPCs with specified CIDR blocks
- Sets up public and private subnets
- Configures routing with Internet and NAT Gateways
- Creates VPC endpoints for S3
- Maintains consistent tagging across all resources

## Prerequisites
- AWS CLI installed and configured with appropriate permissions
- Bash shell environment
- CSV file with the required configuration format

## CSV File Format
The script expects a CSV file named `example.csv` with the following structure:

```csv
region,cidr,private_subnet,public_subnet
us-east-1,10.0.0.0/23,10.0.1.0/24,10.0.2.0/24
```

## Required AWS Permissions
The AWS credentials used must have permissions to:
- Describe, create, and delete VPCs
- Manage subnets
- Create and delete Internet Gateways
- Create and delete NAT Gateways
- Manage route tables
- Create and delete VPC endpoints
- Manage security groups
- Manage Elastic IPs
- Create and manage tags

## Usage
1. Prepare your CSV file with the required configuration
2. Make the script executable:
   ```bash
   chmod +x dspm-vpc-recreate.sh
   ```
3. Run the script:
   ```bash
   ./dspm-vpc-recreate.sh
   ```

## Resource Cleanup
The script first performs a comprehensive cleanup of existing resources in this order:
1. NAT Gateways
2. VPC Endpoints
3. Subnets
4. Route Tables (except main)
5. Internet Gateways
6. Security Groups (except default)
7. Elastic IPs
8. VPCs

## Resource Creation
After cleanup, the script creates new resources in this order:
1. VPC with specified CIDR
2. Internet Gateway
3. Public subnet with auto-assign public IP
4. Private subnet
5. NAT Gateway in public subnet
6. Route tables for both subnets
7. S3 VPC Endpoint

## Tags
The script uses the following tags:
- Key: `dig-security`
- Value: `true`
- Name: Resources are tagged with variations of `dig-securityuse1`

## Error Handling
The script includes comprehensive error handling:
- Exits on any unhandled error (`set -e`)
- Provides detailed error messages with line numbers
- Validates input parameters
- Waits for asynchronous operations to complete (e.g., NAT Gateway creation)
- Continues processing remaining regions if an error occurs in one region

## Output
The script provides detailed logging of:
- Resource deletion progress
- Resource creation status
- Error messages when operations fail
- Success confirmations for each completed region

## Safety Features
- Verifies resource existence before deletion
- Waits for asynchronous operations to complete
- Validates CSV input format
- Checks for required parameters
- Uses separate route tables for public and private subnets

