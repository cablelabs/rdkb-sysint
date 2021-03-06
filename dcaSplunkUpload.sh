#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2016 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################


####
## This script will be invoked upon receiving events from ATOM when processed telemetry dat is available for upload
## This cript is expected to pull the 
####

. /etc/include.properties
. /etc/device.properties

if [ -f /lib/rdk/utils.sh  ]; then
   . /lib/rdk/utils.sh
fi
source /etc/log_timestamp.sh
TELEMETRY_PATH="$PERSISTENT_PATH/.telemetry"
TELEMETRY_RESEND_FILE="$PERSISTENT_PATH/.resend.txt"
TELEMETRY_TEMP_RESEND_FILE="$PERSISTENT_PATH/.temp_resend.txt"

TELEMETRY_PROFILE_DEFAULT_PATH="/tmp/DCMSettings.conf"
TELEMETRY_PROFILE_RESEND_PATH="$PERSISTENT_PATH/.DCMSettings.conf"

RTL_LOG_FILE="$LOG_PATH/dcmscript.log"

HTTP_FILENAME="$TELEMETRY_PATH/dca_httpresult.txt"

DCMRESPONSE="$PERSISTENT_PATH/DCMresponse.txt"

PEER_COMM_ID="/tmp/elxrretyt.swr"

if [ ! -f /usr/bin/GetConfigFile ];then
    echo "Error: GetConfigFile Not Found"
    exit 127
fi

SIGN_FILE="/tmp/.signedRequest_$$_`date +'%s'`"
DIRECT_BLOCK_TIME=86400
DIRECT_BLOCK_FILENAME="/tmp/.lastdirectfail_dca"

SLEEP_TIME_FILE="/tmp/.rtl_sleep_time.txt"
#MAX_LIMIT_RESEND=2
# Max backlog queue set to 5, after which the file will be reset to empty - all data for upload lost
MAX_CONN_QUEUE=5
DIRECT_RETRY_COUNT=2

# exit if an instance is already running
if [ ! -f /tmp/.dca-splunk.upload ];then
    # store the PID
    echo $$ > /tmp/.dca-splunk.upload
else
    pid=`cat /tmp/.dca-splunk.upload`
    if [ -d /proc/$pid ];then
         exit 0
    fi
fi

conn_type_used=""   # Use this to check the connection success, else set to fail
conn_type="Direct" # Use this to check the connection success, else set to fail
first_conn=useDirectRequest
sec_conn=useCodebigRequest
CodebigAvailable=0

CURL_TIMEOUT=30
TLS="--tlsv1.2" 

mkdir -p $TELEMETRY_PATH

# Processing Input Args
inputArgs=$1

# dca_utility.sh does  not uses TELEMETRY_PROFILE_RESEND_PATH, to hardwired to TELEMETRY_PROFILE_DEFAULT_PATH
[ "x$sendInformation" != "x"  ] || sendInformation=1
if [ "$sendInformation" -ne 1 ] ; then
   TELEMETRY_PROFILE_PATH=$TELEMETRY_PROFILE_RESEND_PATH
else
   TELEMETRY_PROFILE_PATH=$TELEMETRY_PROFILE_DEFAULT_PATH
fi
	
echo "Telemetry Profile File Being Used : $TELEMETRY_PROFILE_PATH" >> $RTL_LOG_FILE
	
#Adding support for opt override for dcm.properties file
if [ "$BUILD_TYPE" != "prod" ] && [ -f $PERSISTENT_PATH/dcm.properties ]; then
      . $PERSISTENT_PATH/dcm.properties
else
      . /etc/dcm.properties
fi

if [ -f "$DCMRESPONSE" ]; then    
    DCA_UPLOAD_URL=`grep '"uploadRepository:URL":"' $DCMRESPONSE | awk -F 'uploadRepository:URL":' '{print $NF}' | awk -F '",' '{print $1}' | sed 's/"//g' | sed 's/}//g'`
fi

if [ -z $DCA_UPLOAD_URL ]; then
    echo_t "dca upload url read from dcm.properties is NULL"
    exit 1
fi

pidCleanup()
{
   # PID file cleanup
   if [ -f /tmp/.dca-splunk.upload ];then
        rm -rf /tmp/.dca-splunk.upload
   fi
}

IsDirectBlocked()
{
    ret=0
    if [ -f $DIRECT_BLOCK_FILENAME ]; then
        modtime=$(($(date +%s) - $(date +%s -r $DIRECT_BLOCK_FILENAME)))
        if [ "$modtime" -le "$DIRECT_BLOCK_TIME" ]; then
            echo "dca: Last direct failed blocking is still valid, preventing direct" >>  $RTL_LOG_FILE
            ret=1
        else
            echo "dca: Last direct failed blocking has expired, removing $DIRECT_BLOCK_FILENAME, allowing direct" >> $RTL_LOG_FILE
            rm -f $DIRECT_BLOCK_FILENAME
            ret=0
        fi
    fi
    return $ret
}

# Get the configuration of codebig settings
get_Codebigconfig()
{
   # If GetServiceUrl not available, then only direct connection available and no fallback mechanism
   if [ -f /usr/bin/GetServiceUrl ]; then
      CodebigAvailable=1
   fi
   if [ "$CodebigAvailable" -eq "1" ]; then
       CodeBigEnable=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.CodeBigFirst.Enable | grep true 2>/dev/null`
   fi
   if [ "$CodebigAvailable" -eq "1" ] && [ "x$CodeBigEnable" != "x" ] ; then
      conn_type="Codebig"
      first_conn=useCodebigRequest
      sec_conn=useDirectRequest
   fi

   if [ "$CodebigAvailable" -eq 1 ]; then
      echo_t "dca : Using $conn_type connection as the Primary" >> $RTL_LOG_FILE
   else
      echo_t "dca : Only $conn_type connection is available" >> $RTL_LOG_FILE
   fi
}

# Direct connection Download function
useDirectRequest()
{
       # Direct connection will not be tried if .lastdirectfail exists
       IsDirectBlocked
       if [ "$?" -eq "1" ]; then
           return 1
       fi
      echo_t "dca$2: Using Direct commnication"
      CURL_CMD="curl $TLS -w '%{http_code}\n' --interface $EROUTER_INTERFACE $addr_type -H \"Accept: application/json\" -H \"Content-type: application/json\" -X POST -d '$1' -o \"$HTTP_FILENAME\" \"$DCA_UPLOAD_URL\" --connect-timeout $CURL_TIMEOUT -m $CURL_TIMEOUT"
      echo_t "CURL_CMD: $CURL_CMD" >> $RTL_LOG_FILE
      HTTP_CODE=`result= eval $CURL_CMD`
      ret=$?

      http_code=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
      [ "x$http_code" != "x" ] || http_code=0

      echo_t "dca $2 : Direct Connection HTTP RESPONSE CODE : $http_code" >> $RTL_LOG_FILE
    # log security failure
      case $ret in
        35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
           echo_t "dca$2: Direct Connection Failure - ret:$ret http_code:$http_code" >> $RTL_LOG_FILE
           ;;
      esac
      if [ $http_code -eq 200 ]; then
           echo_t "dca$2: Direct connection success - ret:$ret http_code:$http_code" >> $RTL_LOG_FILE
           # Use direct connection for rest of the connections
           conn_type_used="Direct"
           return 0
      fi
    if [ "$ret" -eq 0 ]; then
        echo_t "dca$2: Direct Connection Failure - ret:$ret http_code:$http_code" >> $RTL_LOG_FILE
    fi
    direct_retry=$(( direct_retry += 1 ))
    if [ "$direct_retry" -ge "$DIRECT_RETRY_COUNT" ]; then
       # .lastdirectfail will not be created for only direct connection 
       [ "$CodebigAvailable" -ne "1" ] || [ -f $DIRECT_BLOCK_FILENAME ] || touch $DIRECT_BLOCK_FILENAME
    fi
    sleep 10
    return 1
}

# Codebig connection Download function
useCodebigRequest()
{
      # Do not try Codebig if CodebigAvailable != 1 (GetServiceUrl not there)
      if [ "$CodebigAvailable" -eq "0" ] ; then
         echo "dca$2 : Only direct connection Available"
         return 1
      fi
      SIGN_CMD="GetServiceUrl 9 "
      eval $SIGN_CMD > $SIGN_FILE
      CB_SIGNED_REQUEST=`cat $SIGN_FILE`
      rm -f $SIGN_FILE
      CURL_CMD="curl $TLS -w '%{http_code}\n' --interface $EROUTER_INTERFACE $addr_type -H \"Accept: application/json\" -H \"Content-type: application/json\" -X POST -d '$1' -o \"$HTTP_FILENAME\" \"$CB_SIGNED_REQUEST\" --connect-timeout $CURL_TIMEOUT -m $CURL_TIMEOUT"
      echo_t "dca$2: Using Codebig connection at `echo "$CURL_CMD" | sed -ne 's#.*\(https:.*\)?.*#\1#p'`" >> $RTL_LOG_FILE
      echo_t "CURL_CMD: `echo "$CURL_CMD" | sed -ne 's#oauth_consumer_key=.*oauth_signature=.* --#<hidden> --#p'`" >> $RTL_LOG_FILE
      HTTP_CODE=`result= eval $CURL_CMD`
      curlret=$?
      http_code=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
      [ "x$http_code" != "x" ] || http_code=0
      # log security failure
      echo_t "dca $2 : Codebig Connection HTTP RESPONSE CODE : $http_code" >> $RTL_LOG_FILE
      case $curlret in
          35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
             echo_t "dca$2: Codebig Connection Failure - ret:$curlret http_code:$http_code" >> $RTL_LOG_FILE
             ;;
      esac
      if [ "$http_code" -eq 200 ]; then
           echo_t "dca$2: Codebig connection success - ret:$curlret http_code:$http_code" >> $RTL_LOG_FILE
           conn_type_used="Codebig"
           return 0
      fi
      if [ "$curlret" -eq 0 ]; then
          echo_t "dca$2: Codebig Connection Failure - ret:$curlret http_code:$http_code" >> $RTL_LOG_FILE
      fi
      sleep 10
    return 1
}

timestamp=`date +%Y-%b-%d_%H-%M-%S`
#main app
estbMac=`getErouterMacAddress`
cur_time=`date "+%Y-%m-%d %H:%M:%S"`

# If interface doesnt have ipv6 address then we will force the curl to go with ipv4.
# Otherwise we will not specify the ip address family in curl options
addr_type=""
[ "x`ifconfig $EROUTER_INTERFACE | grep inet6 | grep -i 'Global'`" != "x" ] || addr_type="-4"

if [ "x$DCA_MULTI_CORE_SUPPORTED" = "xyes" ]; then
   ##  1]  Pull processed data from ATOM 
   rm -f $TELEMETRY_JSON_RESPONSE

   
   GetConfigFile $PEER_COMM_ID
   scp -i $PEER_COMM_ID root@$ATOM_INTERFACE_IP:$TELEMETRY_JSON_RESPONSE $TELEMETRY_JSON_RESPONSE > /dev/null 2>&1
   if [ $? -ne 0 ]; then
       scp -i $PEER_COMM_ID root@$ATOM_INTERFACE_IP:$TELEMETRY_JSON_RESPONSE $TELEMETRY_JSON_RESPONSE > /dev/null 2>&1
   fi
   echo_t "Copied $TELEMETRY_JSON_RESPONSE " >> $RTL_LOG_FILE 
   rm -f $PEER_COMM_ID
   sleep 2
fi

# Add the erouter MAC address from ARM as this is not available in ATOM
sed -i -e "s/ErouterMacAddress/$estbMac/g" $TELEMETRY_JSON_RESPONSE


if [ ! -f $SLEEP_TIME_FILE ]; then
    if [ -f $DCMRESPONSE ]; then
        cron=`cat $DCMRESPONSE | grep -i TelemetryProfile | awk -F '"schedule":' '{print $NF}' | awk -F "," '{print $1}' | sed 's/://g' | sed 's/"//g' | sed -e 's/^[ ]//' | sed -e 's/^[ ]//'`
    fi

    if [ -n "$cron" ]; then
        sleep_time=`echo "$cron" | awk -F '/' '{print $2}' | cut -d ' ' -f1`
    fi 

    if [ -n "$sleep_time" ];then
        sleep_time=`expr $sleep_time - 1` #Subtract 1 miute from it
        sleep_time=`expr $sleep_time \* 60` #Make it to seconds
        # Adding generic RANDOM number implementation as sh in RDK_B doesn't support RANDOM
        RANDOM=`awk -v min=5 -v max=10 'BEGIN{srand(); print int(min+rand()*(max-min+1)*(max-min+1)*1000)}'`
        sleep_time=$(($RANDOM%$sleep_time)) #Generate a random value out of it
        echo "$sleep_time" > $SLEEP_TIME_FILE
    else
        sleep_time=10
    fi
else 
    sleep_time=`cat $SLEEP_TIME_FILE`
fi

if [ -z "$sleep_time" ];then
    sleep_time=10
fi

if [ "$inputArgs" = "logbackup_without_upload" ];then
      echo_t "log backup during bootup, Will upload on later call..!"
      if [ -f $TELEMETRY_JSON_RESPONSE ]; then
           outputJson=`cat $TELEMETRY_JSON_RESPONSE`
      fi
      if [ ! -f $TELEMETRY_JSON_RESPONSE ] || [ "x$outputJson" = "x" ] ; then
               echo_t "dca: Unable to find Json message or Json is empty." >> $RTL_LOG_FILE
         if [ ! -f /etc/os-release ];then pidCleanup; fi
         exit 0 
      fi
      if [ -f $TELEMETRY_RESEND_FILE ]; then 
          mv $TELEMETRY_RESEND_FILE $TELEMETRY_TEMP_RESEND_FILE 
      fi
      # ensure that Json is put at the top of the queue
      echo "$outputJson" > $TELEMETRY_RESEND_FILE
      if [ -f $TELEMETRY_TEMP_RESEND_FILE ] ; then
         cat $TELEMETRY_TEMP_RESEND_FILE >> $TELEMETRY_RESEND_FILE
         rm -f $TELEMETRY_TEMP_RESEND_FILE
      fi
      # In case the file gets greater that Queue, truncate to max lenght
      if [ -f $TELEMETRY_RESEND_FILE ]; then
          if [ "`cat $TELEMETRY_RESEND_FILE | wc -l `" -ge "$MAX_CONN_QUEUE" ]; then
              mv $TELEMETRY_RESEND_FILE $TELEMETRY_TEMP_RESEND_FILE
              no_of_json=$(( MAX_CONN_QUEUE -1 ))
              cat $TELEMETRY_TEMP_RESEND_FILE | sed -ne '1,'"$no_of_json"' p' > $TELEMETRY_RESEND_FILE
              rm -f $TELEMETRY_TEMP_RESEND_FILE
          fi
      fi
      if [ ! -f /etc/os-release ];then pidCleanup; fi
      exit 0
fi
get_Codebigconfig
direct_retry=0
##  2] Check for unsuccessful posts from previous execution in resend que.
##  If present repost either with appending to existing or as independent post
if [ -f $TELEMETRY_RESEND_FILE ]; then
    rm -f $TELEMETRY_TEMP_RESEND_FILE
    while read resend
    do
        echo_t "dca resend : $resend" >> $RTL_LOG_FILE 
        $first_conn "$resend" "resend" || $sec_conn "$resend" "resend" ||  conn_type_used="Fail" 

        if [ "x$conn_type_used" = "xFail" ] ; then 
           echo "$resend" >> $TELEMETRY_TEMP_RESEND_FILE
           echo_t "dca Connecion failed for this Json : requeuing back"  >> $RTL_LOG_FILE 
        fi 
        echo_t "dca Attempting next Json in the queue "  >> $RTL_LOG_FILE 
        sleep 10 
   done < $TELEMETRY_RESEND_FILE
   sleep 2
   rm -f $TELEMETRY_RESEND_FILE
   if [ -f $TELEMETRY_TEMP_RESEND_FILE ]; then
        if [ "`cat $TELEMETRY_TEMP_RESEND_FILE | wc -l `" -ge "$MAX_CONN_QUEUE" ]; then
               rm $TELEMETRY_TEMP_RESEND_FILE
        fi
   fi
fi

##  3] Attempt to post current message. Check for status if failed add it to resend queue
if [ -f $TELEMETRY_JSON_RESPONSE ]; then
   outputJson=`cat $TELEMETRY_JSON_RESPONSE`
fi
if [ ! -f $TELEMETRY_JSON_RESPONSE ] || [ "x$outputJson" = "x" ] ; then
    echo_t "dca: Unable to find Json message or Json is empty." >> $RTL_LOG_FILE
    [ ! -f $TELEMETRY_TEMP_RESEND_FILE ] ||  mv $TELEMETRY_TEMP_RESEND_FILE $TELEMETRY_RESEND_FILE
    if [ ! -f /etc/os-release ];then pidCleanup; fi
    exit 0
fi

echo "$outputJson" > $TELEMETRY_RESEND_FILE
# sleep for random time before upload to avoid bulk requests on splunk server
echo_t "dca: Sleeping for $sleep_time before upload." >> $RTL_LOG_FILE
sleep $sleep_time
timestamp=`date +%Y-%b-%d_%H-%M-%S`
$first_conn "$outputJson"  || $sec_conn "$outputJson"  ||  conn_type_used="Fail" 
if [ "x$conn_type_used" != "xFail" ]; then
    echo_t "dca: Json message successfully submitted." >> $RTL_LOG_FILE
    rm -f $TELEMETRY_RESEND_FILE
    [ ! -f $TELEMETRY_TEMP_RESEND_FILE ] ||  mv $TELEMETRY_TEMP_RESEND_FILE $TELEMETRY_RESEND_FILE
else
   if [ -f $TELEMETRY_TEMP_RESEND_FILE ] ; then
       cat $TELEMETRY_TEMP_RESEND_FILE >> $TELEMETRY_RESEND_FILE
       rm -f $TELEMETRY_TEMP_RESEND_FILE
    fi
    echo_t "dca: Json message submit failed. Adding message to resend queue" >> $RTL_LOG_FILE
fi
rm -f $TELEMETRY_JSON_RESPONSE
# PID file cleanup
if [ ! -f /etc/os-release ];then pidCleanup; fi
