#!/bin/sh


####
## This script will be invoked upon receiving events from ATOM when processed telemetry dat is available for upload
## This cript is expected to pull the 
####

. /etc/include.properties
. /etc/device.properties

if [ -f /lib/rdk/utils.sh  ]; then
   . /lib/rdk/utils.sh
fi

TELEMETRY_PATH="$PERSISTENT_PATH/.telemetry"
TELEMETRY_RESEND_FILE="$PERSISTENT_PATH/.resend.txt"
TELEMETRY_TEMP_RESEND_FILE="$PERSISTENT_PATH/.temp_resend.txt"

TELEMETRY_PROFILE_DEFAULT_PATH="/tmp/DCMSettings.conf"
TELEMETRY_PROFILE_RESEND_PATH="$PERSISTENT_PATH/.DCMSettings.conf"

RTL_LOG_FILE="$LOG_PATH/dcmscript.log"

HTTP_FILENAME="$TELEMETRY_PATH/dca_httpresult.txt"
HTTP_CODE="$TELEMETRY_PATH/dca_curl_httpcode"

DCMRESPONSE="$PERSISTENT_PATH/DCMresponse.txt"
SLEEP_TIME_FILE="/tmp/.rtl_sleep_time.txt"
MAX_LIMIT_RESEND=5
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

mkdir -p $TELEMETRY_PATH

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
    DCA_UPLOAD_URL="https://stbrtl.xcal.tv"
fi

pidCleanup()
{
   # PID file cleanup
   if [ -f /tmp/.dca-splunk.upload ];then
        rm -rf /tmp/.dca-splunk.upload
   fi
}

timestamp=`date +%Y-%b-%d_%H-%M-%S`
#main app
estbMac=`getErouterMacAddress`
cur_time=`date "+%Y-%m-%d %H:%M:%S"`

if [ "x$DCA_MULTI_CORE_SUPPORTED" = "xyes" ]; then
   ##  1]  Pull processed data from ATOM 
   rm -f $TELEMETRY_JSON_RESPONSE
   scp root@$ATOM_INTERFACE_IP:$TELEMETRY_JSON_RESPONSE $TELEMETRY_JSON_RESPONSE
   if [ $? -ne 0 ]; then
       scp root@$ATOM_INTERFACE_IP:$TELEMETRY_JSON_RESPONSE $TELEMETRY_JSON_RESPONSE
   fi
   echo "$timestamp: Copied $TELEMETRY_JSON_RESPONSE " >> $RTL_LOG_FILE 
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

##  2] Check for unsuccessful posts from previous execution in resend que.
##  If present repost either with appending to existing or as independent post
retry=0
if [ -f $TELEMETRY_RESEND_FILE ]; then
    rm -f $TELEMETRY_TEMP_RESEND_FILE
    while read resend
    do
        echo "$timestamp: dca resend : $resend" >> $RTL_LOG_FILE 
	CURL_CMD="curl -w '%{http_code}\n' --interface $EROUTER_INTERFACE -H \"Accept: application/json\" -H \"Content-type: application/json\" -X POST -d '$resend' -o \"$HTTP_FILENAME\" \"$DCA_UPLOAD_URL\" --connect-timeout 30 -m 10 --insecure"
        ret= eval $CURL_CMD > $HTTP_CODE
        echo "$timestamp: dca resend : CURL_CMD: $CURL_CMD" >> $RTL_LOG_FILE 
	sleep 5
	http_code=$(awk -F\" '{print $1}' $HTTP_CODE)
        echo "$timestamp: dca resend : HTTP RESPONSE CODE : $http_code" >> $RTL_LOG_FILE
        if [ "$http_code" != "200" ]; then
            # Store this line from resend file to a temp resend file
            # This is to address the use case when device is offline
            echo "$resend" >> $TELEMETRY_TEMP_RESEND_FILE
        fi
        # Sleep between resending the events while connectivity is down
        sleep 30 
        retry=$((retry + 1))
        if [ $retry -gt $MAX_LIMIT_RESEND ]; then
            echo "$timestamp: dca Max limit for resend attempts reached. Ignoring messages in resend list" >> $RTL_LOG_FILE 
            break
        fi
   done < $TELEMETRY_RESEND_FILE
   sleep 2
   if [ "$http_code" == "200" ]; then
       rm -f $TELEMETRY_RESEND_FILE
   fi

   if [ -f $TELEMETRY_TEMP_RESEND_FILE ]; then
       mv $TELEMETRY_TEMP_RESEND_FILE $TELEMETRY_RESEND_FILE
   fi
fi

##  3] Attempt to post current message. Check for status if failed add it to resend que
if [ ! -f $TELEMETRY_JSON_RESPONSE ]; then
    echo "$timestamp: dca: Unable to find Json message ." >> $RTL_LOG_FILE
    if [ ! -f /etc/os-release ];then pidCleanup; fi
    exit 0
fi

outputJson=`cat $TELEMETRY_JSON_RESPONSE`
timestamp=`date +%Y-%b-%d_%H-%M-%S` 
CURL_CMD="curl -w '%{http_code}\n' --interface $EROUTER_INTERFACE -H \"Accept: application/json\" -H \"Content-type: application/json\" -X POST -d '$outputJson' -o \"$HTTP_FILENAME\" \"$DCA_UPLOAD_URL\" --connect-timeout 30 -m 10 --insecure"
echo "$timestamp: dca: CURL_CMD: $CURL_CMD" >> $RTL_LOG_FILE 
# sleep for random time before upload to avoid bulk requests on splunk server
echo "$timestamp: dca: Sleeping for $sleep_time before upload." >> $RTL_LOG_FILE
sleep $sleep_time
timestamp=`date +%Y-%b-%d_%H-%M-%S`
ret= eval $CURL_CMD > $HTTP_CODE
http_code=$(awk -F\" '{print $1}' $HTTP_CODE)
echo "$timestamp: dca: HTTP RESPONSE CODE : $http_code" >> $RTL_LOG_FILE
if [ $http_code -eq 200 ];then
    echo "$timestamp: dca: Json message successfully submitted." >> $RTL_LOG_FILE
else
    echo "$timestamp: dca: Json message submit failed. Adding message to resend que" >> $RTL_LOG_FILE
    echo "$outputJson" >> $TELEMETRY_RESEND_FILE
fi

rm -f $TELEMETRY_JSON_RESPONSE
# PID file cleanup
if [ ! -f /etc/os-release ];then pidCleanup; fi
