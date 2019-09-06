#!/bin/bash

sudo -i <<'EOF'
echo "export DSS_USER=<DSS_USER>" > /opt/dataiku/variable.sh
echo "export YOUR_DSS_USER=<YOUR_DSS_USER>" >> /opt/dataiku/variable.sh
echo "export YOUR_USER_PASSWORD=<YOUR_USER_PASSWORD>" >> /opt/dataiku/variable.sh
echo "export HIVESERVER2_HOST=<HIVESERVER2_HOST>" >> /opt/dataiku/variable.sh
chmod 777 /opt/dataiku/variable.sh
EOF


echo -----------------------------
echo Install automation node
echo -----------------------------

source /opt/dataiku/variable.sh

sudo su - $DSS_USER <<'EOF'
source /opt/dataiku/variable.sh
cd /opt/dataiku
./dataiku-dss-5.1.3/installer.sh -t automation -d /opt/dataiku/auto_dir -p 12000 -l /data/$DSS_USER/license.json
EOF

source /opt/dataiku/variable.sh
sudo -i "/opt/dataiku/dataiku-dss-5.1.3/scripts/install/install-boot.sh" "/opt/dataiku/auto_dir" $DSS_USER
sudo yum install -y jq

## Uncomment if you installed R integration and want to do so on the Automation Node as well
#echo -----------------------------
#echo Install R integration
#echo -----------------------------
#
#sudo su  $DSS_USER <<'EOF'
#source /opt/dataiku/variable.sh
#cd /opt/dataiku
#./auto_dir/bin/dssadmin install-R-integration
#EOF


echo -----------------------------
echo Install hadoop integration
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /opt/dataiku/variable.sh
cd /opt/dataiku
kdestroy
kinit -kt /opt/dataiku/security/$DSS_USER.keytab $DSS_USER@TRAINING.DATAIKU.COM
klist -e
./auto_dir/bin/dssadmin install-hadoop-integration -keytab /data/$DSS_USER/$DSS_USER.keytab -principal $DSS_USER@TRAINING.DATAIKU.COM
EOF


echo -----------------------------
echo Install Spark integration
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /opt/dataiku/variable.sh
cd /opt/dataiku
./auto_dir/bin/dssadmin install-spark-integration
EOF


echo -----------------------------
echo Install multiUserSecurity
echo -----------------------------
source /opt/dataiku/variable.sh
sudo /opt/dataiku/auto_dir/bin/dssadmin install-impersonation $DSS_USER


echo -----------------------------
echo Set up multiUserSecurity
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /opt/dataiku/variable.sh
cd /opt/dataiku
echo "export INSTALL_ID=$(cat ./auto_dir/install.ini | grep installid | awk -F' = ' '{print $2}')" >> /opt/dataiku/variable.sh
EOF

source /opt/dataiku/variable.sh
sudo sed -i "s/allowed_user_groups =/allowed_user_groups = ${DSS_USER}_users/" /etc/dataiku-security/$INSTALL_ID/security-config.ini
sudo cat /etc/dataiku-security/$INSTALL_ID/security-config.ini

echo -----------------------------
echo Start automation node
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
cd /opt/dataiku
./auto_dir/bin/dss start 
EOF

echo "sleeping 10s to allow DSS to start"
sleep 10
echo "awake!"

echo -----------------------------
echo Generate API Key
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /opt/dataiku/variable.sh
cd /opt/dataiku
AUTO_JSON=$(./auto_dir/bin/dsscli api-key-create --output json --admin true --description "admin key for automation node setup script" --label "auto_script_key")
echo "export AUTO_KEY=$(echo $AUTO_JSON | jq '.[] | .key')" >> /opt/dataiku/variable.sh
cho $AUTO_KEY
EOF

source /opt/dataiku/variable.sh

echo -----------------------------
echo Create Sql connection
echo ----------------------------

source /opt/dataiku/variable.sh
echo ' 
import requests
import json
import os 

HOST = "http://localhost:12000/public/api"
PATH="/admin/connections/"
API_KEY=os.environ["AUTO_KEY"]

DATA = {
    "params": {
        "host": "localhost",
        "user": "dataiku",
        "password": "dataiku",
        "db": "dataiku"
    },
    "name": "postgres_conn",
    "type": "PostgreSQL",
    "allowWrite": True,
    "allowManagedDatasets": True,
    "allowManagedFolders": True,
    "usableBy": "ALL"
    }

r = requests.post(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(DATA), verify=False)
print r.text' > create_postgres_conn.py

python ./create_postgres_conn.py


echo -----------------------------
echo Update HDFS connection
echo ----------------------------

source /opt/dataiku/variable.sh
echo ' 
import requests
import json
import os 

HOST = "http://localhost:12000/public/api"
PATH="/admin/connections/hdfs_managed"
API_KEY=os.environ["AUTO_KEY"]

r = requests.get(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, verify=False)
hdfs_conn=json.loads(r.text)

hdfs_conn["params"]["aclSynchronizationMode"] = "NONE"
hdfs_conn["params"]["namingRule"] = {
    "hdfsPathDatasetNamePrefix": "${projectKey}/",
    "tableNameDatasetNamePrefix": "${projectKey}_",
    "hiveDatabaseName": "%s" %os.environ["DSS_USER"],
    "uploadsPathPrefix": "uploads"
}

r = requests.put(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(hdfs_conn), verify=False)
print r.text' > update_hdfs_conn.py

python ./update_hdfs_conn.py


echo -----------------------------
echo Configure DSS - Hadoop, Spark, and MUS
echo -----------------------------

source /opt/dataiku/variable.sh
echo ' 
import requests
import json
import os 

HOST = "http://localhost:12000/public/api"
PATH="/admin/general-settings/"
API_KEY=os.environ["AUTO_KEY"]

r = requests.get(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, verify=False)
dss_settings=json.loads(r.text)


user_mapping ={
    "dssUser": os.environ["YOUR_DSS_USER"],
    "type": "SINGLE_MAPPING",
    "scope": "GLOBAL",
    "targetHadoop": "%s-user1" %os.environ["DSS_USER"],
    "targetUnix": "%s-user1" %os.environ["DSS_USER"]
}

group_mapping = {
    "targetHadoop": "%s-users" %os.environ["DSS_USER"],
    "targetUnix": "%s-users" %os.environ["DSS_USER"],
    "type": "SINGLE_MAPPING",
    "dssGroup": "biz_x_data_scientists"
}

default_spark_config = [
	{"name" : "default",
	 "description": " default configuration",
	 "conf": [{"key":"spark.master", "value": "yarn-client"}]
	}
]

hive_settings = {
    "enabled": True,
    "engineCreationSettings": {
        "executionEngine": "HIVESERVER2"
    },
    "hiveServer2Host": os.environ["HIVESERVER2_HOST"],
    "hiveServer2Port": 10000,
    "hiveServer2Principal": "hive/_HOST@TRAINING.DATAIKU.COM",
    "useURL": False
}

dss_settings["impersonation"]["userRules"].insert(0,user_mapping)
dss_settings["impersonation"]["groupRules"].insert(0,group_mapping)
dss_settings["hiveSettings"]=hive_settings
dss_settings["sparkSettings"]["executionConfigs"]=default_spark_config

r = requests.put(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(dss_settings), verify=False)
print r.text
print "Configuration Complete!"' > modify_global_config.py

python ./modify_global_config.py


echo -----------------------------
echo Create User and Group User and Group 
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /opt/dataiku/variable.sh
cd /opt/dataiku
./auto_dir/bin/dsscli group-create --description "Data Scientists from Business X" --source-type LOCAL --may-create-project true --may-write-unsafe-code true --may-write-safe-code true --may-create-code-envs true --may-develop-plugins true --may-create-published-api-services true biz_x_data_scientists
./auto_dir/bin/dsscli user-create --source-type LOCAL --display-name $YOUR_DSS_USER --user-profile DATA_SCIENTIST --group biz_x_data_scientists $YOUR_DSS_USER $YOUR_USER_PASSWORD
echo "Finished with User and Group Creation!"
EOF

