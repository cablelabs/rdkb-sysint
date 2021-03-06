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
#

. /etc/include.properties
. /etc/device.properties

usage()
{
  echo "USAGE:   startTunnel.sh {start|stop} {args}"
}

if [ -f /lib/rdk/utils.sh  ]; then
   . /lib/rdk/utils.sh
fi

if [ $# -lt 1 ]; then
   usage
   exit 1
fi

ip_to_hex() {
  printf '%02x' ${1//./ }
}

oper=$1
shift

case $oper in 
           h)
             usage
             exit 1
             ;;
           start)
             if [ $BOX_TYPE = "XF3" ]; then
                # PACE XF3 and PACE CFG3
                CM_IP=`ifconfig $CMINTERFACE | grep inet6 | tr -s " " | grep -v Link | cut -d " " -f4 | cut -d "/" -f1`
             elif [ "$BOX_TYPE" = "TCCBR" ] || [ "$MODEL_NUM" = "CGM4140COM" ]; then
                # TCH XB6 and TCH CBR
                # getting the IPV4 address for CM
                CM_IPV4=`ifconfig privbr:0 | grep "inet addr" | awk '/inet/{print $2}'  | cut -f2 -d:`
                IpCheckVal=$(echo ${CM_IPV4} | tr "." " " | awk '{ print $3"."$4 }')
                Check=$(ip_to_hex $IpCheckVal)
                # getting the IPV6 address for CM
                CM_IP=`ifconfig privbr | grep $Check |  awk '/inet6/{print $3}' | cut -d '/' -f1`
                CM_IP="$CM_IP%privbr"
             else
                # OTHER PLATFORMS
                CM_IP=`getCMIPAddress`
             fi
             # Replace CM_IP with value
             args=`echo $* | sed "s/CM_IP/$CM_IP/g"`
             ID="/tmp/nvgeajacl.ipe"

             if [ ! -f /usr/bin/GetConfigFile ];then
                 echo "Error: GetConfigFile Not Found"
                 exit 127
             fi
             GetConfigFile $ID
             /usr/bin/ssh -i $ID $args
             rm $ID
             exit 1
             ;;
           stop)
             cat /var/tmp/rssh.pid |xargs kill -9
             rm /var/tmp/rssh.pid
             exit 1
             ;;
           *)
             usage
             exit 1
esac
