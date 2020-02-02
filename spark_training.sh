#!/bin/bash

sudo -i <<'EOF'
export TRAINING_NAME=<TRAINING_ENV_NAME>
export README=$(sudo find /data/ -name "README.txt")
export DSS_USER=$(sudo sh -c "sed -n 's/Hive database:          //p' < $README")
export HIVESERVER2_HOST=$(sudo sh -c "sed -n 's/Hiverserver host:       //p' < $README")

echo "export DSS_USER=$DSS_USER" > /tmp/variable.sh
echo "export YOUR_DSS_USER=data_scientist" >> /tmp/variable.sh
echo "export YOUR_USER_PASSWORD=Dataiku!@#123" >> /tmp/variable.sh
echo "export HIVESERVER2_HOST=$HIVESERVER2_HOST" >> /tmp/variable.sh
echo "export DSS_VERSION=6.0.2" >> /tmp/variable.sh
echo "export DSS_DESIGN_URL=http://$DSS_USER-design-$TRAINING_NAME.training.dataiku.com" >> /tmp/variable.sh
chmod 777 /tmp/variable.sh
EOF


echo -----------------------------
echo Setup base Dir
echo -----------------------------
source /tmp/variable.sh

echo $DSS_USER
echo $DSS_VERSION 

sudo mkdir /data/dataiku
sudo chown -R $DSS_USER:$DSS_USER /data/dataiku


sudo wget https://cdn.downloads.dataiku.com/public/dss/$DSS_VERSION/dataiku-dss-$DSS_VERSION.tar.gz -O /data/dataiku/dataiku-dss-$DSS_VERSION.tar.gz
sudo tar -xzvf /data/dataiku/dataiku-dss-$DSS_VERSION.tar.gz -C /data/dataiku/
sudo chown -R $DSS_USER:$DSS_USER /data/dataiku/dataiku-dss-$DSS_VERSION

echo -----------------------------
echo Install Design node
echo -----------------------------

source /tmp/variable.sh

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
./dataiku-dss-$DSS_VERSION/installer.sh -d /data/dataiku/data_dir -p 11000 -l /data/$DSS_USER/license.json
EOF

source /tmp/variable.sh
sudo -i "/data/dataiku/dataiku-dss-$DSS_VERSION/scripts/install/install-boot.sh" "/data/dataiku/data_dir" $DSS_USER
sudo yum install -y jq

## Uncomment if you installed R integration and want to do so on the Automation Node as well
#echo -----------------------------
#echo Install R integration -- design
#echo -----------------------------
#
#sudo su  $DSS_USER <<'EOF'
#source /tmp/variable.sh
#cd /data/dataiku
#./data_dir/bin/dssadmin install-R-integration
#EOF

echo -----------------------------
echo Install hadoop integration -- design
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
kdestroy
kinit -kt /data/$DSS_USER/$DSS_USER.keytab $DSS_USER@TRAINING.DATAIKU.COM
klist -e
./data_dir/bin/dssadmin install-hadoop-integration -keytab /data/$DSS_USER/$DSS_USER.keytab -principal $DSS_USER@TRAINING.DATAIKU.COM
EOF

echo -----------------------------
echo Install Spark integration -- design
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
./data_dir/bin/dssadmin install-spark-integration
EOF


echo -----------------------------
echo Install multiUserSecurity -- design
echo -----------------------------
source /tmp/variable.sh
sudo /data/dataiku/data_dir/bin/dssadmin install-impersonation $DSS_USER


echo -----------------------------
echo Set up multiUserSecurity -- design
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
echo "export INSTALL_ID=$(cat ./data_dir/install.ini | grep installid | awk -F' = ' '{print $2}')" >> /tmp/variable.sh
EOF

source /tmp/variable.sh
sudo sed -i "s/allowed_user_groups =/allowed_user_groups = ${DSS_USER}-users/" /etc/dataiku-security/$INSTALL_ID/security-config.ini
sudo cat /etc/dataiku-security/$INSTALL_ID/security-config.ini

echo -----------------------------
echo Start design node
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
cd /data/dataiku
./data_dir/bin/dss start 
EOF

echo "sleeping 10s to allow DSS to start"
sleep 10
echo "awake!"

echo -----------------------------
echo Generate API Key -- design
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
AUTO_JSON=$(./data_dir/bin/dsscli api-key-create --output json --admin true --description "admin key for design node setup script" --label "design_script_key")
echo "export AUTO_KEY=$(echo $AUTO_JSON | jq '.[] | .key')" >> /tmp/variable.sh
source /tmp/variable.sh
echo $AUTO_KEY
EOF

source /tmp/variable.sh

echo -----------------------------
echo Create Sql connection -- design
echo ----------------------------

source /tmp/variable.sh
echo ' 
import requests
import json
import os 
HOST = "http://localhost:11000/public/api"
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
print r.text' > /tmp/create_postgres_conn.py

python /tmp/create_postgres_conn.py


echo -----------------------------
echo Update HDFS connection -- design 
echo ----------------------------

source /tmp/variable.sh
echo ' 
import requests
import json
import os 
HOST = "http://localhost:11000/public/api"
PATH="/admin/connections/hdfs_managed"
API_KEY=os.environ["AUTO_KEY"]
r = requests.get(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, verify=False)
hdfs_conn=json.loads(r.text)
hdfs_conn["params"]["root"] = "/user/%s/dss_managed_datasets" %os.environ["DSS_USER"]
hdfs_conn["params"]["aclSynchronizationMode"] = "NONE"
hdfs_conn["params"]["namingRule"] = {
    "hdfsPathDatasetNamePrefix": "${projectKey}/",
    "tableNameDatasetNamePrefix": "${projectKey}_",
    "hiveDatabaseName": "%s" %os.environ["DSS_USER"],
    "uploadsPathPrefix": "uploads"
}
hdfs_conn["params"]["aclSynchronizationMode"] = "NONE"
hdfs_conn["detailsReadability"]["readableBy"] = "ALL"
r = requests.put(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(hdfs_conn), verify=False)
print r.text

#modify hdfs_root conn so details are readableBy
PATH="/admin/connections/hdfs_root"
r = requests.get(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, verify=False)
hdfs_conn=json.loads(r.text)
hdfs_conn["detailsReadability"]["readableBy"] = "ALL"
r = requests.put(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(hdfs_conn), verify=False)
print r.text

#create hdfs_replace_me
PATH="/admin/connections/"
DATA = {
            "params": {
                "root": "/user/%s/dss_managed_datasets" %os.environ["DSS_USER"],
                "defaultDatabase": "%s" %os.environ["DSS_USER"],
                "namingRule": {
                    "hdfsPathDatasetNamePrefix": "${projectKey}/",
                    "tableNameDatasetNamePrefix": "${projectKey}_",
                    "hiveDatabaseName": "%s" %os.environ["DSS_USER"],
                    "uploadsPathPrefix": "uploads"
                },
                "aclSynchronizationMode": "NONE",
                "clearMode": "DSS_USER",
            },
            "name": "hdfs_replace_me",
            "type": "HDFS",
            "allowWrite": True,
            "allowManagedDatasets": True,
            "allowManagedFolders": True,
            "usableBy": "ALL",
            "detailsReadability": {
                "readableBy": "NONE"
            }
        }

r = requests.post(url=HOST+PATH, auth=(API_KEY, ""), headers={"Content-Type":"application/json"}, data=json.dumps(DATA), verify=False)
print r.text
' > /tmp/update_hdfs_conn.py

python /tmp/update_hdfs_conn.py

echo -----------------------------
echo Configure DSS - Hadoop, Spark, and MUS -- design
echo -----------------------------

source /tmp/variable.sh
echo ' 
import requests
import json
import os 
HOST = "http://localhost:11000/public/api"
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
print "Configuration Complete!"' > /tmp/modify_global_config.py

python /tmp/modify_global_config.py


echo -----------------------------
echo Create User and Group User and Group -- design
echo -----------------------------

sudo su - $DSS_USER <<'EOF'
source /tmp/variable.sh
cd /data/dataiku
./data_dir/bin/dsscli group-create --description "Data Scientists from Business X" --source-type LOCAL --may-create-project true --may-write-unsafe-code true --may-write-safe-code true --may-create-code-envs true --may-develop-plugins true --may-create-published-api-services true biz_x_data_scientists
./data_dir/bin/dsscli user-create --source-type LOCAL --display-name $YOUR_DSS_USER --user-profile DESIGNER --group biz_x_data_scientists $YOUR_DSS_USER $YOUR_USER_PASSWORD
echo "Finished with User and Group Creation!"
EOF

echo -----------------------------
echo install python packages
echo -----------------------------

#ignore installed, due to issue w/ ipaddress version
sudo pip install --ignore-installed mail-parser
sudo pip install setuptools -U
sudo pip install nltk
sudo python -m nltk.downloader -d /usr/local/share/nltk_data all
