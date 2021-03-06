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
# Script responsible for log upload based on protocol

source /etc/utopia/service.d/log_env_var.sh
source /etc/utopia/service.d/log_capture_path.sh

. $RDK_LOGGER_PATH/utils.sh 
. $RDK_LOGGER_PATH/logfiles.sh

SIGN_FILE="/tmp/.signedRequest_$$_`date +'%s'`"
DIRECT_BLOCK_TIME=86400
DIRECT_BLOCK_FILENAME="/tmp/.lastdirectfail_upl"

UseCodeBig=0
conn_str="Direct"
first_conn=useDirectRequest
sec_conn=useCodebigRequest
CodebigAvailable=0

encryptionEnable=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.EncryptCloudUpload.Enable | grep value | cut -d ":" -f 3 | tr -d ' '`
URLENCODE_STRING=""

if [ $# -ne 4 ]; then 
     #echo "USAGE: $0 <TFTP Server IP> <UploadProtocol> <UploadHttpLink> <uploadOnReboot>"
     echo "USAGE: $0 $1 $2 $3 $4"
fi

if [ -f /etc/os-release ] || [ -f /etc/device.properties ]; then
   export PATH=$PATH:/fss/gw/
   CURL_BIN="curl"
else
   CURL_BIN=/fss/gw/curl
fi

# assign the input arguments

UploadProtocol=$2
UploadHttpLink=$3
UploadOnReboot=$4

if [ "$5" != "" ]; then
	nvram2Backup=$5
else
    backupenabled=`syscfg get logbackup_enable`
    nvram2Supported="no"
    if [ -f /etc/device.properties ]
    then
       nvram2Supported=`cat /etc/device.properties | grep NVRAM2_SUPPORTED | cut -f2 -d=`
    fi

    if [ "$nvram2Supported" = "yes" ] && [ "$backupenabled" = "true" ]
    then
       nvram2Backup="true"
    else
       nvram2Backup="false"
    fi
fi

UploadPath=$6

SECONDV=`dmcli eRT getv Device.X_CISCO_COM_CableModem.TimeOffset | grep value | cut -d ":" -f 3 | tr -d ' ' `

getFWVersion()
{
	verStr=`cat /version.txt | grep ^imagename: | cut -d ":" -f 2`
	echo $verStr
}

getBuildType()
{
        # Currenlty this function not used. If used please ensure, calling get_Codebigconfig before this call
        # get_Codebigconfig currenlty called in HttpLogUpload 
	if [ "$UseCodeBig" = "1" ]; then
		IMAGENAME=`cat /fss/gw/version.txt | grep ^imagename: | cut -d ":" -f 2`
	else
		IMAGENAME=`cat /fss/gw/version.txt | grep ^imagename= | cut -d "=" -f 2`
	fi

   TEMPDEV=`echo $IMAGENAME | grep DEV`
   if [ "$TEMPDEV" != "" ]
   then
       echo "DEV"
   fi
 
   TEMPVBN=`echo $IMAGENAME | grep VBN`
   if [ "$TEMPVBN" != "" ]
   then
       echo "VBN"
   fi

   TEMPPROD=`echo $IMAGENAME | grep PROD`
   if [ "$TEMPPROD" != "" ]
   then
       echo "PROD"
   fi
   
   TEMPCQA=`echo $IMAGENAME | grep CQA`
   if [ "$TEMPCQA" != "" ]
   then
       echo "CQA"
   fi
   
}

if [ "$UploadHttpLink" == "" ]
then
	UploadHttpLink=$URL
fi

# initialize the variables
MAC=`getMacAddressOnly`
HOST_IP=`getIPAddress`
dt=`date "+%m-%d-%y-%I-%M%p"`
LOG_FILE=$MAC"_Logs_$dt.tgz"
CM_INTERFACE="wan0"
WAN_INTERFACE="erouter0"
CURLPATH="/fss/gw"
CA_CERT="/etc/cacert.pem"

VERSION="/fss/gw/version.txt"

http_code=0
OutputFile='/tmp/httpresult.txt'

# Function which will upload logs to TFTP server

retryUpload()
{
	while : ; do
	   sleep 10
	   WAN_STATE=`sysevent get wan_service-status`
       EROUTER_IP=`ifconfig $WAN_INTERFACE | grep "inet addr" | cut -d":" -f2 | cut -d" " -f1`
       SYSEVENT_PID=`pidof syseventd`
	   if [ -f $WAITINGFORUPLOAD ]
	   then
		   if [ "$WAN_STATE" == "started" ] && [ "$EROUTER_IP" != "" ]
		   then
			touch $REGULAR_UPLOAD
			HttpLogUpload
			rm $REGULAR_UPLOAD
			rm $WAITINGFORUPLOAD

  		   elif [ "$EROUTER_IP" != "" ] && [ "$SYSEVENT_PID" == "" ]
		   then
			touch $REGULAR_UPLOAD
			HttpLogUpload
			rm $REGULAR_UPLOAD
			rm $WAITINGFORUPLOAD
		   fi
	   else
		break
	   fi
	done
		
}

IsDirectBlocked()
{
    ret=0
    if [ -f $DIRECT_BLOCK_FILENAME ]; then
        modtime=$(($(date +%s) - $(date +%s -r $DIRECT_BLOCK_FILENAME)))
        if [ "$modtime" -le "$DIRECT_BLOCK_TIME" ]; then
            echo "Last direct failed blocking is still valid, preventing direct"
            ret=1
        else
            echo "Last direct failed blocking has expired, removing $DIRECT_BLOCK_FILENAME, allowing direct"
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
      UseCodeBig=1 
      conn_str="Codebig"
      first_conn=useCodebigRequest
      sec_conn=useDirectRequest
   fi

   if [ "$CodebigAvailable" -eq 1 ]; then
      echo_t "Using $conn_str connection as the Primary"
   else
      echo_t "Only $conn_str connection is available"
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
    # Direct Communication
    # Performing 3 tries for successful curl command execution.
    # $http_code --> Response code retrieved from HTTP_CODE file path.
    echo_t "Trying Direct Communication"
    retries=0
    while [ "$retries" -lt 3 ]
    do
        echo_t "Trial $retries for DIRECT ..."
        # nice value can be normal as the first trial failed
            CURL_CMD="$CURL_BIN --tlsv1.2 -w '%{http_code}\n' -d \"filename=$UploadFile\" $URLENCODE_STRING -o \"$OutputFile\" --cacert $CA_CERT --interface $WAN_INTERFACE $addr_type \"$S3_URL\" --connect-timeout 30 -m 30"
            echo_t "Curl Command built: $CURL_CMD"
        if [ $retries -ne 0 ]
        then
            #echo_t "Checking if file still exists !!!"
            if [[ ! -e $UploadFile ]]; then
                  echo_t "No file exist or already uploaded!!!"
                  break;
            fi

            echo_t "CURL_CMD:$CURL_CMD"
            HTTP_CODE=`ret= eval $CURL_CMD`

            if [ "x$HTTP_CODE" != "x" ]; then
                http_code=$(echo "$HTTP_CODE" | awk '{print $0}' )
                echo_t "Direct Communication - ret:$ret, http_code:$http_code"
                if [ "$http_code" != "" ];then
                    echo_t "Direct connection HttpCode received is : $http_code"
                    if [ $http_code -eq 200 ] || [ $http_code -eq 302 ] ;then
                        return 0
                    fi
                fi
            else
                http_code=0
                echo_t "Direct Communication Failure Attempt:$retries - ret:$ret, http_code:$http_code"
            fi
        fi
               
        retries=`expr $retries + 1`
        sleep 30
    done
    echo "Retries for Direct connection exceeded " 
    [ "$CodebigAvailable" -ne "1" ] || [ -f $DIRECT_BLOCK_FILENAME ] || touch $DIRECT_BLOCK_FILENAME
    return 1
}

# Codebig connection Download function        
useCodebigRequest()
{
    # Do not try Codebig if CodebigAvailable != 1 (GetServiceUrl not there)
    if [ "$CodebigAvailable" -eq "0" ] ; then
        echo "Log Upload : Only direct connection Available" 
        return 1
    fi
    echo_t "Trying Codebig Communication"
    retries=0
    while [ "$retries" -lt 10 ]
    do
        echo "Trial $retries..."

        if [ $retries -ne 0 ]; then
            if [ -f /nvram/adjdate.txt ]; then
                echo -e "$0  --> /nvram/adjdate exist. It is used by another program"
                echo -e "$0 --> Sleeping 10 seconds and try again\n"
            else
                echo -e "$0  --> /nvram/adjdate NOT exist. Writing date value"
                dateString=`date +'%s'`
                if [ "x$SECONDV" != "x" ]; then
                    count=$(expr $dateString - $SECONDV)
                else
                    count=$dateString
                fi
                echo "$0  --> date adjusted:"
                date -d @$count
                echo $count > /nvram/adjdate.txt
                break
            fi
        fi

        retries=`expr $retries + 1`
        sleep 10
    done
    if [ ! -f /nvram/adjdate.txt ];then
        echo "LOG UPLOAD UNSUCCESSFUL TO S3 because unable to write date info to /nvram/adjdate.txt"
        rm -rf $UploadFile
        exit
    fi
    retries=0
    while [ "$retries" -lt 3 ]
    do
        SIGN_CMD="GetServiceUrl 1 \"/cgi-bin/rdkb.cgi?filename=$UploadFile\""
        eval $SIGN_CMD > $SIGN_FILE
        if [ -s /tmp/.signedRequest ]
        then
            echo "Log upload - GetServiceUrl success"
        else
            echo "Log upload - GetServiceUrl failed"
            exit 1
        fi

        CB_SIGNED=`cat $SIGN_FILE`
        rm -f $SIGN_FILE
        [ ! -f /nvram/adjdate.txt ] || rm -f /nvram/adjdate.txt
        S3_URL_SIGN=`echo $CB_SIGNED | sed -e "s|?.*||g"`
        echo "serverUrl : $S3_URL_SIGN"
        authorizationHeader=`echo $CB_SIGNED | sed -e "s|&|\", |g" -e "s|=|=\"|g" -e "s|.*filename|filename|g"`
        authorizationHeader="Authorization: OAuth realm=\"\", $authorizationHeader\""

        CURL_CMD="$CURL_BIN --tlsv1.2 --cacert $CA_CERT --connect-timeout 30 --interface $WAN_INTERFACE $addr_type -H '$authorizationHeader' -w '%{http_code}\n' $URLENCODE_STRING -o \"$OutputFile\" -d \"filename=$UploadFile\" '$S3_URL_SIGN'"
            #Sensitive info like Authorization signature should not print
        CURL_CMD_FOR_ECHO="$CURL_BIN --tlsv1.2 --cacert $CA_CERT --connect-timeout 30 --interface $WAN_INTERFACE $addr_type -H <Hidden authorization-header> -w '%{http_code}\n' $URLENCODE_STRING -o \"$OutputFile\" -d \"filename=$UploadFile\" '$S3_URL_SIGN'"

        echo_t "File to be uploaded: $UploadFile"
        UPTIME=`uptime`
        echo_t "System Uptime is $UPTIME"
        echo_t "S3 URL is : $S3_URL_SIGN"

        # Performing 3 tries for successful curl command execution.
        # $http_code --> Response code retrieved from HTTP_CODE file path.
        #echo_t "Checking if file still exists !!!"
	if [[ ! -e $UploadFile ]]; then
             echo_t "No file exist or already uploaded!!!"
             break;
        fi

        echo_t "Trial $retries for CODEBIG..."
        # nice value can be normal as the first trial failed
        if [ $retries -ne 0 ]
        then
            #Sensitive info like Authorization signature should not print
            echo "Curl Command built: $CURL_CMD_FOR_ECHO"
            HTTP_CODE=`ret= eval $CURL_CMD`

            if [ "x$HTTP_CODE" != "x" ];
            then
                http_code=$(echo "$HTTP_CODE" | awk '{print $0}' )
                echo_t "Codebig Communication - ret:$ret, http_code:$http_code"

                if [ "$http_code" != "" ];then
                    echo_t "Codebig connection HttpCode received is : $http_code"
                    if [ $http_code -eq 200 ] || [ $http_code -eq 302 ] ;then
                        return 0
                    fi
		    if [ $http_code -eq 429 ];then
                        echo_t "Codebig Communication Failure HttpCode received is : $http_code"
                        http_code=0
			sleep 30
                    fi
                fi
            else
                http_code=0
                echo_t "Codebig Communication Failure Attempt:$retries - ret:$ret, http_code:$http_code"
            fi
        fi

        retries=`expr $retries + 1`
        sleep 30
    done
    echo "Retries for Codebig connection exceeded " 
    return 1
}

# Function which will upload logs to HTTP S3 server
HttpLogUpload()
{   

    # If interface doesnt have ipv6 address then we will force the curl to go with ipv4.
    # Otherwise we will not specify the ip address family in curl options
    addr_type=""
    [ "x`ifconfig $WAN_INTERFACE | grep inet6 | grep -i 'Global'`" != "x" ] || addr_type="-4"

    # Upload logs to "LOG_BACK_UP_REBOOT" upon reboot else to the default path "LOG_BACK_UP_PATH"	
	if [ "$UploadOnReboot" == "true" ]; then
		if [ "$nvram2Backup" == "true" ]; then
			cd $LOG_SYNC_BACK_UP_REBOOT_PATH
		else
			cd $LOG_BACK_UP_REBOOT
		fi
	else
		if [ "$nvram2Backup" == "true" ]; then
			cd $LOG_SYNC_BACK_UP_PATH
		else
			cd $LOG_BACK_UP_PATH
		fi
	fi

	if [ "$UploadPath" != "" ] && [ -d $UploadPath ]; then
		FILE_NAME=`ls $UploadPath | grep "tgz"`
		if [ "$FILE_NAME" != "" ]; then
			cd $UploadPath
		fi
	fi
 
   UploadFile=`ls | grep "tgz"`
 
   # This check is to handle migration scenario from /nvram to /nvram2
   if [ "$UploadFile" = "" ] && [ "$nvram2Backup" = "true" ]
   then
       echo_t "Checking if any file available in $LOG_BACK_UP_REBOOT"
       UploadFile=`ls $LOG_BACK_UP_REBOOT | grep tgz`
       if [ "$UploadFile" != "" ]
       then
         cd $LOG_BACK_UP_REBOOT
       fi
   fi
   echo_t "files to be uploaded is : $UploadFile"

    S3_URL=$UploadHttpLink
    file_list=$UploadFile

    get_Codebigconfig
    for UploadFile in $file_list
    do
        echo_t "Upload file is : $UploadFile"
#        CURL_CMD="nice -n 20 $CURL_BIN --tlsv1.2 -w '%{http_code}\n' -d \"filename=$UploadFile\" -o \"$OutputFile\" --cacert $CA_CERT --interface $WAN_INTERFACE $addr_type \"$S3_URL\" --connect-timeout 30 -m 30"

        echo_t "File to be uploaded: $UploadFile"
        UPTIME=`uptime`
        echo_t "System Uptime is $UPTIME"
        echo_t "S3 URL is : $S3_URL"

        echo "RFC_EncryptCloudUpload_Enable:$encryptionEnable"
        if [ "$encryptionEnable" == "true" ]; then
            S3_MD5SUM="$(openssl md5 -binary < $UploadFile | openssl enc -base64)"
            URLENCODE_STRING="--data-urlencode \"md5=$S3_MD5SUM\""
        fi

        $first_conn || $sec_conn || { echo_t "INVALID RETURN CODE: $http_code" ; echo_t "LOG UPLOAD UNSUCCESSFUL TO S3" ; continue ; }

        # If 200, executing second curl command with the public key.
        if [ $http_code -eq 200 ];then
            #This means we have received the key to which we need to curl again in order to upload the file.
            #So get the key from FILENAME
            Key=$(awk -F\" '{print $0}' $OutputFile)

            # if url uses http, then log and force https (RDKB-13142)
            echo "$Key" | tr '[:upper:]' '[:lower:]' | grep -q -e 'http://'
            if [ $? -eq 0 ]; then
                echo_t "LOG UPLOAD TO S3 requested http. Forcing to https"
                Key=$(echo "$Key" | sed -e 's#http://#https://#g' -e 's#:80/#:443/#')
                forced_https="true"
            else
                forced_https="false"
            fi

            #RDKB-14283 Remove Signature from CURL command in consolelog.txt and ArmConsolelog.txt
            RemSignature=`echo $Key | sed "s/AWSAccessKeyId=.*Signature=.*&//g;s/\"//g;s/.*https/https/g"`

            if [ "$encryptionEnable" != "true" ]; then
                Key=\"$Key\"
            fi

            echo_t "Generated KeyIs : "
            echo $RemSignature

            CURL_CMD="nice -n 20 $CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type $Key --connect-timeout 30 -m 30"
            #Sensitive info like Authorization signature should not print
            CURL_CMD_FOR_ECHO="nice -n 20 $CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type \"<hidden key>\" --connect-timeout 30 -m 30"

            retries=0
            while [ "$retries" -lt 3 ]
            do
                echo_t "Trial $retries..."
                # nice value can be normal as the first trial failed
                if [ $retries -ne 0 ]; then
                    CURL_CMD="$CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type $Key --connect-timeout 30 -m 30"
                      #Sensitive info like Authorization signature should not print
                    CURL_CMD_FOR_ECHO="$CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type \"<hidden key>\" --connect-timeout 30 -m 30"
                fi

               #echo_t "Checking if file still exists !!!"
	       if [[ ! -e $UploadFile ]]; then
                   echo_t "No file exist or already uploaded!!!"
                   break;
               fi

                #Sensitive info like Authorization signature should not print
                echo_t "Curl Command built: $CURL_CMD_FOR_ECHO"
                HTTP_CODE=`eval $CURL_CMD `
                ret=$?

                #Check for forced https security failure
                if [ "$forced_https" = "true" ]; then
                    case $ret in
                        35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
                            echo_t "LOG UPLOAD TO S3 forced https failed"
                    esac
                fi

                if [ "x$HTTP_CODE" != "x" ]; then
                    http_code=$(echo "$HTTP_CODE" | awk '{print $0}' )

                    if [ "$http_code" != "" ];then
                        echo_t "HttpCode received is : $http_code"
                        if [ $http_code -eq 200 ];then
                            break
                        fi
                    fi
                else
                    http_code=0
                fi

                retries=`expr $retries + 1`
                sleep 30
            done

            # Response after executing curl with the public key is 200, then file uploaded successfully.
            if [ $http_code -eq 200 ];then
                echo_t "LOGS UPLOADED SUCCESSFULLY, RETURN CODE: $http_code"
                rm -rf $UploadFile
            fi

        #When 302, there is URL redirection.So get the new url from FILENAME and curl to it to get the key.
        elif [ $http_code -eq 302 ];then
            NewUrl=$(grep -oP "(?<=HREF=\")[^\"]+(?=\")" $OutputFile)

            # if url uses http, then log and force https (RDKB-13142)
            echo "$NewUrl" | tr '[:upper:]' '[:lower:]' | grep -q -e 'http://'
            if [ $? -eq 0 ]; then
                echo_t "LOG UPLOAD TO S3 requested http. Forcing to https"
                NewUrl=$(echo "$NewUrl" | sed -e 's#http://#https://#g' -e 's#:80/#:443/#')
                forced_https="true"
            else
                forced_https="false"
            fi

            CURL_CMD="nice -n 20 $CURL_BIN --tlsv1.2 -w '%{http_code}\n' -d \"filename=$UploadFile\" -o \"$OutputFile\" \"$NewUrl\" --interface $WAN_INTERFACE $addr_type --connect-timeout 30 -m 30"

            retries=0
            while [ "$retries" -lt 3 ]
            do
                echo_t "Trial $retries..."
                # nice value can be normal as the first trial failed
                if [ $retries -ne 0 ]; then
                     CURL_CMD="$CURL_BIN --tlsv1.2 -w '%{http_code}\n' -d \"filename=$UploadFile\" $URLENCODE_STRING -o \"$OutputFile\" --cacert $CA_CERT --interface $WAN_INTERFACE $addr_type \"$S3_URL\" --connect-timeout 30 -m 30"
                fi

               #echo_t "Checking if file still exists !!!"
	       if [[ ! -e $UploadFile ]]; then
                   echo_t "No file exist or already uploaded!!!"
                   break;
               fi

                echo_t "Curl Command built: $CURL_CMD"
                HTTP_CODE=`eval $CURL_CMD` 
                ret=$?

                #Check for forced https security failure
                if [ "$forced_https" = "true" ]; then
                    case $ret in
                        35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
                            echo_t "LOG UPLOAD TO S3 forced https failed"
                    esac
                fi

                if [ "x$HTTP_CODE" != "x" ]; then
                    http_code=$(echo "$HTTP_CODE" | awk '{print $0}' )

                    if [ "$http_code" != "" ];then
                        echo_t "HttpCode received is : $http_code"
                        if [ $http_code -eq 200 ];then
                            break
                        fi
                    fi
                else
                    http_code=0
                fi
                retries=`expr $retries + 1`
                sleep 30
            done



            #Executing curl with the response key when return code after the first curl execution is 200.
            if [ $http_code -eq 200 ];then
                Key=$(awk '{print $0}' $OutputFile)
                if [ "$encryptionEnable" != "true" ]; then
                    Key=\"$Key\"
                fi
                CURL_CMD="nice -n 20 $CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type $Key --connect-timeout 10 -m 10"
                #Sensitive info like Authorization signature should not print
                CURL_CMD_FOR_ECHO="nice -n 20 $CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type \"<hidden key>\" --connect-timeout 10 -m 10"

                retries=0
                while [ "$retries" -lt 3 ]
                do
                    echo_t "Trial $retries..."
                    # nice value can be normal as the first trial failed
                    if [ $retries -ne 0 ]; then
                        CURL_CMD="$CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type  $Key --connect-timeout 10 -m 10"
                            #Sensitive info like Authorization signature should not print
                        CURL_CMD_FOR_ECHO="$CURL_BIN --tlsv1.2 -w '%{http_code}\n' -T $UploadFile -o \"$OutputFile\" --interface $WAN_INTERFACE $addr_type \"<hidden key>\" --connect-timeout 10 -m 10"
                    fi
               
                   #echo_t "Checking if file still exists !!!"
	           if [[ ! -e $UploadFile ]]; then
                       echo_t "No file exist or already uploaded!!!"
                       break;
		   fi

                    #Sensitive info like Authorization signature should not print
                    echo_t "Curl Command built: $CURL_CMD_FOR_ECHO"
                    HTTP_CODE=`ret= eval $CURL_CMD`
                    if [ "x$HTTP_CODE" != "x" ]; then
                        http_code=$(echo "$HTTP_CODE" | awk '{print $0}' )

                        if [ "$http_code" != "" ];then

                            if [ $http_code -eq 200 ];then
                                break
                            fi
                        fi
                    else
                        http_code=0
                    fi
                    retries=`expr $retries + 1`
                    sleep 30
                done
                #Logs upload successful when the return code is 200 after the second curl execution.
                if [ $http_code -eq 200 ];then
                    echo_t "LOGS UPLOADED SUCCESSFULLY, RETURN CODE: $http_code"
                    result=0
                    rm -rf $UploadFile
                fi
            fi
        else
            echo_t "INVALID RETURN CODE: $http_code"
            echo_t "LOG UPLOAD UNSUCCESSFUL TO S3"
            rm -rf $UploadFile
        fi
        echo_t $result
    done

    if [ "$UploadPath" != "" ] && [ -d $UploadPath ]; then
        rm -rf $UploadPath
    fi
        
}


# Flag that a log upload is in progress. 
if [ -e $REGULAR_UPLOAD ]
then
	rm $REGULAR_UPLOAD
fi

if [ -f $WAITINGFORUPLOAD ]
then
	rm -rf $WAITINGFORUPLOAD
fi

touch $REGULAR_UPLOAD

#Check the protocol through which logs need to be uploaded
if [ "$UploadProtocol" = "HTTP" ]
then
   WAN_STATE=`sysevent get wan_service-status`
   EROUTER_IP=`ifconfig $WAN_INTERFACE | grep "inet addr" | cut -d":" -f2 | cut -d" " -f1`
   SYSEVENT_PID=`pidof syseventd`
   if [ "$WAN_STATE" == "started" ] && [ "$EROUTER_IP" != "" ]
   then
	   echo_t "Upload HTTP_LOGS"
	   HttpLogUpload
   elif [ "$EROUTER_IP" != "" ] && [ "$SYSEVENT_PID" == "" ]
   then
	   echo_t "syseventd is crashed, $WAN_INTERFACE has IP Uploading HTTP_LOGS"
	   HttpLogUpload
   else
	   echo_t "WAN is down, waiting for Upload LOGS"
	   touch $WAITINGFORUPLOAD
	   retryUpload &
   fi
fi

# Remove the log in progress flag
rm $REGULAR_UPLOAD
# removing event which is set in backupLogs.sh when wan goes down
sysevent set wan_event_log_upload no
