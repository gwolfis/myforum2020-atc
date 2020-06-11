#!/bin/bash

# Script must be non-blocking or run in the background.

mkdir -p /config/cloud

cat << 'EOF' > /config/cloud/startup-script.sh

#!/bin/bash

# BIG-IPS ONBOARD SCRIPT

LOG_FILE=${onboard_log}

if [ ! -e $LOG_FILE ]
then
     touch $LOG_FILE
     exec &>>$LOG_FILE
else
    #if file exists, exit as only want to run once
    exit
fi

exec 1>$LOG_FILE 2>&1

# WAIT FOR BIG-IP SYSTEMS & API TO BE UP
curl -o /config/cloud/utils.sh -s --fail --retry 60 -m 10 -L https://raw.githubusercontent.com/F5Networks/f5-cloud-libs/develop/scripts/util.sh
. /config/cloud/utils.sh
wait_for_bigip

### CHECK IF DNS IS CONFIGURED YET, IF NOT, SLEEP
echo "CHECK THAT DNS IS READY"
nslookup github.com
if [ $? -ne 0 ]; then
  echo "DNS NOT READY, SLEEP 30 SECS"
  sleep 30
fi

### GET SECRET VIA DEFAULT REQUESTS LIB ON BIG-IP
echo "GET BIG-IP PASSWORD FROM AWS SECRET MANAGER"
role_name=$(curl -s "http://169.254.169.254/latest/meta-data/iam/security-credentials/" )
payload=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/$role_name)
export AWS_ACCESS_KEY_ID=$(printf "$payload" | jq -r ".AccessKeyId")
export AWS_SECRET_ACCESS_KEY=$(printf "$payload" | jq -r ".SecretAccessKey")
export AWS_TOKEN=$(printf "$payload" | jq -r ".Token")
export AWS_REGION=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone| sed s/.$//`
export SECRET_ID=${secret_id}

### WRITE PYTHON FILE TO DISK
cat > secrets_manager.py << END_TEXT
# Copyright 2010-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# This file is licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License. A copy of the
# License is located at
#
# http://aws.amazon.com/apache2.0/
#
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

# AWS Version 4 signing example

# See: http://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
# This version makes a POST request and passes request parameters
# in the body (payload) of the request. Auth information is passed in
# an Authorization header.
import sys, os, base64, datetime, hashlib, hmac 
import requests 
import json

# Read AWS access key from env. variables or configuration file. Best practice is NOT
# to embed credentials in code.
access_key = os.environ.get('AWS_ACCESS_KEY_ID')
secret_key = os.environ.get('AWS_SECRET_ACCESS_KEY')
token = os.environ.get('AWS_TOKEN')
region = os.environ.get('AWS_REGION')
secret_id = os.environ.get('SECRET_ID')
if access_key is None:
    print('No access key was provided.')
    sys.exit()
if secret_key is None:
    print('No secret key was provided.')
    sys.exit()
if token is None:
    print('No token was provided.')
    sys.exit()
if region is None:
    print('No region was provided.')
    sys.exit()
if secret_id is None:
    print('No secret_id was provided.')
    sys.exit()
# ************* REQUEST VALUES *************
method = 'POST'
service = 'secretsmanager'
host = 'secretsmanager.'+ region + '.amazonaws.com'
endpoint = 'https://secretsmanager.'+ region +'.amazonaws.com/'
content_type = 'application/x-amz-json-1.1'
amz_target = 'secretsmanager.GetSecretValue'

# Request parameters for GetSecretValue--passed in a JSON block.
request_parameters =  '{'
request_parameters +=  '"SecretId": "'+ secret_id +'"'
request_parameters +=  '}'

# Key derivation functions. See:
# http://docs.aws.amazon.com/general/latest/gr/signature-v4-examples.html#signature-v4-examples-python
def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

def getSignatureKey(key, date_stamp, regionName, serviceName):
    kDate = sign(('AWS4' + key).encode('utf-8'), date_stamp)
    kRegion = sign(kDate, regionName)
    kService = sign(kRegion, serviceName)
    kSigning = sign(kService, 'aws4_request')
    return kSigning

# Create a date for headers and the credential string
t = datetime.datetime.utcnow()
amz_date = t.strftime('%Y%m%dT%H%M%SZ')
date_stamp = t.strftime('%Y%m%d') # Date w/o time, used in credential scope


# ************* TASK 1: CREATE A CANONICAL REQUEST *************
# http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html

# Step 1 is to define the verb (GET, POST, etc.)--already done.

# Step 2: Create canonical URI--the part of the URI from domain to query 
# string (use '/' if no path)
canonical_uri = '/'

## Step 3: Create the canonical query string. In this example, request
# parameters are passed in the body of the request and the query string
# is blank.
canonical_querystring = ''

# Step 4: Create the canonical headers. Header names must be trimmed
# and lowercase, and sorted in code point order from low to high.
# Note that there is a trailing \n.
canonical_headers = 'content-type:' + content_type + '\n' + 'host:' + host + '\n' + 'x-amz-date:' + amz_date + '\n' + 'x-amz-target:' + amz_target + '\n'

# Step 5: Create the list of signed headers. This lists the headers
# in the canonical_headers list, delimited with ";" and in alpha order.
# Note: The request can include any headers; canonical_headers and
# signed_headers include those that you want to be included in the
# hash of the request. "Host" and "x-amz-date" are always required.
signed_headers = 'content-type;host;x-amz-date;x-amz-target'

# Step 6: Create payload hash. In this example, the payload (body of
# the request) contains the request parameters.
payload_hash = hashlib.sha256(request_parameters.encode('utf-8')).hexdigest()

# Step 7: Combine elements to create canonical request
canonical_request = method + '\n' + canonical_uri + '\n' + canonical_querystring + '\n' + canonical_headers + '\n' + signed_headers + '\n' + payload_hash

# ************* TASK 2: CREATE THE STRING TO SIGN*************
# Match the algorithm to the hashing algorithm you use, either SHA-1 or
# SHA-256 (recommended)
algorithm = 'AWS4-HMAC-SHA256'
credential_scope = date_stamp + '/' + region + '/' + service + '/' + 'aws4_request'
string_to_sign = algorithm + '\n' +  amz_date + '\n' +  credential_scope + '\n' +  hashlib.sha256(canonical_request.encode('utf-8')).hexdigest()

# ************* TASK 3: CALCULATE THE SIGNATURE *************
# Create the signing key using the function defined above.
signing_key = getSignatureKey(secret_key, date_stamp, region, service)

# Sign the string_to_sign using the signing_key
signature = hmac.new(signing_key, (string_to_sign).encode('utf-8'), hashlib.sha256).hexdigest()

# ************* TASK 4: ADD SIGNING INFORMATION TO THE REQUEST *************
# Put the signature information in a header named Authorization.
authorization_header = algorithm + ' ' + 'Credential=' + access_key + '/' + credential_scope + ', ' +  'SignedHeaders=' + signed_headers + ', ' + 'Signature=' + signature
headers = {'Content-Type':content_type,
           'X-Amz-Date':amz_date,
           'X-Amz-Target':amz_target,
           'Authorization':authorization_header,
           'X-Amz-Security-Token': token}


# ************* SEND THE REQUEST *************

r = requests.post(endpoint, request_parameters, headers=headers)

print(r.text)
END_TEXT

### SET BIG-IP PASSWORD
echo "SET THE BIG-IP PASSWORD"
pwd=$(python secrets_manager.py | jq -r ".SecretString")
if [ -z "$pwd" ]
then
  echo "ERROR: UNABLE TO OBTAIN PASSWORD"
else
  tmsh modify auth user admin password $pwd
fi

### DOWNLOAD ONBOARDING PKGS
# Could be pre-packaged or hosted internally
mkdir -p ${libs_dir}

DO_URL='${DO_URL}'
DO_FN=$(basename "$DO_URL")
AS3_URL='${AS3_URL}'
AS3_FN=$(basename "$AS3_URL")
TS_URL='${TS_URL}'
TS_FN=$(basename "$TS_URL")

echo -e "\n"$(date) "Download Declarative Onboarding Pkg"
curl -L -o ${libs_dir}/$DO_FN $DO_URL
sleep 20

echo -e "\n"$(date) "Download AS3 Pkg"
curl -L -o ${libs_dir}/$AS3_FN $AS3_URL
sleep 20

echo -e "\n"$(date) "Download TS Pkg"
curl -L -o ${libs_dir}/$TS_FN $TS_URL
sleep 20

# Copy the RPM Pkg to the file location
cp ${libs_dir}/*.rpm /var/config/rest/downloads/

# Install Declarative Onboarding Pkg
DATA="{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/$DO_FN\"}"
echo -e "\n"$(date) "Install DO Pkg"
restcurl -X POST "shared/iapp/package-management-tasks" -d $DATA

# Install AS3 Pkg
DATA="{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/$AS3_FN\"}"
echo -e "\n"$(date) "Install AS3 Pkg"
restcurl -X POST "shared/iapp/package-management-tasks" -d $DATA

# Install TS Pkg
DATA="{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/$TS_FN\"}"
echo -e "\n"$(date) "Install TS Pkg"
restcurl -X POST "shared/iapp/package-management-tasks" -d $DATA


date
echo "FINISHED STARTUP SCRIPT"

### Clean up
rm /config/cloud/startup-script.sh 
EOF

# Now run in the background to not block startup
chmod 755 /config/cloud/startup-script.sh 
nohup /config/cloud/startup-script.sh &
