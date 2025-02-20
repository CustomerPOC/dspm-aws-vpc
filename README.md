# VPC CIDR and Subnet Update Script

## Overview
This script automates the process of updating AWS VPC CIDR blocks and associated subnets across multiple regions. It reads configuration from a CSV file and performs the following operations:
- Associates new CIDR blocks with tagged VPCs
- Creates new public and private subnets
- Maintains existing routing configurations
- Removes old CIDR blocks and subnets

## Prerequisites
- AWS CLI installed and configured with appropriate permissions
- Bash shell environment
- CSV file with the required configuration format

## CSV File Format
The script expects a CSV file named `example.csv` with the following structure:

```csv
region,cidr,private_subnet,public_subnet
us-east-1,10.0.0.0/16,10.0.1.0/24,10.0.2.0/24
```

## Required AWS Permissions
The AWS credentials used must have permissions to:
- Describe and modify VPCs
- Create and delete subnets
- Describe and associate route tables
- Create and modify tags

## Usage
1. Prepare your CSV file with the required configuration
2. Make the script executable:
   ```bash
   chmod +x update-vpc.sh
   ```
3. Run the script:
   ```bash
   ./update-vpc.sh
   ```

## Error Handling
The script includes comprehensive error handling:
- Validates input parameters
- Checks for resource existence before operations
- Provides detailed error messages
- Continues processing remaining regions if an error occurs in one region

## Tags
The script looks for VPCs with the following tag:
- Key: `dig-security`
- Value: `true`

## Output
The script provides detailed logging of:
- Current operation status
- Error messages when operations fail
- Success confirmations for each completed region

## Notes
- The script will skip processing a region if required resources are not found
- Existing subnets are deleted only after new subnets are successfully created
- The script uses the first availability zone in each region for new subnets

## Safety Features
- Exits on any unhandled error (`set -e`)
- Verifies resource existence before modifications
- Maintains routing configurations during subnet updates

