#!/bin/bash
# vim: noai:ts=2:sw=2:hls
# Author: Cameron Pierce
# Purpose: log top CPU consumers when the load is too high
# Modified: 2017-02-23
# Version: 1.5
# Changelog:
#       1.0 - initial release
#       1.1 - add support for MacOS
#       1.2 - add support for arguments w/ verbose mode
#       1.3 - convert to check_mk local check
#       1.4 - logging and monitoring cleanup
#       1.5 - use top instead of ps for more details
#
# Future release considerations:
#       - email when high CPU use reported
#       - one-liner log for ELK recording/shipping
#       - daily summary email when run at set time
#
# Requirements:
#       MacOS/Ubuntu/CentOS:
#               - bc binary for calculating float point values
#       Ubuntu/CentOS:
#               - nproc binary for counting number of processors
#               - /proc/loadavg file for identifying the 1 minute CPU average
#
# Output:
#       - stdout - commented lines marked w/ 'DEBUG' for testing purposes
#       - fileLogLoad - log file, written to when load exceeds intLoadRateCalc
#       - fileTemp - lock and PID tracking temp file
################################################################################

#set -x # DEBUG

## VARIABLES ###################################################################

# measure the runtime internally
dateSTART=$(date +"%s")
# get the date first
DATE=$(date +"%Y-%m-%d_%H:%M:%S")

# Percent of each CPU we allow to be consumed before tracking CPU use, where 1 is 100% of each CPUs load and 0.25 is 1/4 of each CPUs load
intLoadRate=0.08

# whether to run verbosely, disabled by default, use -v to enable
intVerbose=1

# identify the OS type
OS=$OSTYPE
# darwin16 = MacOS

#echo $OSTYPE # DEBUG

# if this script is running on MacOS then calculate the number of processors using an alertnative method
if [ $OSTYPE == "darwin16" ]; then
        # MacOS Load calculation from /proc # doesn't exist in MacOS
        intLoad=`w | grep "load average" | awk '{print $10}'`

        # MacOS Core, Processor, and sum of both
        intCores=`system_profiler SPHardwareDataType | grep "Processors" | awk '{print $4}'`
        intProcessors=`system_profiler SPHardwareDataType | grep "Cores" | awk '{print $5}'`
        intProcCount=` echo "${intCores} * ${intProcessors}" | bc -l`

        # set the file where we will keep a log of the top CPU consumers when CPU use is high
        fileLogLoad=~/monitorload.log # write to homedir on MacOS
else
        # Ubuntu / CentOS Load calculation from /proc # doesn't exist in MacOS
        intLoad=`awk '{print $1}' /proc/loadavg`

        # Ubuntu / CentOS Processor count # doesn't exist in MacOS
        intProcCount=`nproc`

        # set the file where we will keep a log of the top CPU consumers when CPU use is high
        fileLogLoad=/var/log/monitorload.log
        #fileLogLoad=~/monitorload.log # DEBUG - write to homedir
fi

# set PID for tracking PS info
strPID=$$
# get name of script for tracking
strScriptName="$(basename $0 | cut -d. -f1 )"

# set name and path of temp file for script tracking
fileTemp=/tmp/${strScriptName}.tmp

## PRE-MAIN ####################################################################

# if fileTemp exists then abort; previous script may be hung or script may have a bug
if [ -f ${fileTemp} ]; then
        echo "$DATE $strScriptName - Aborted. temp file exists. Previous script may be hung or still running." >> $fileLogLoad
        echo "3 $strScriptName - UNKNOWN - temp file exists and previous script may be hung or still running"
        exit 1
else
        # Save PID to temp file
        echo ${strPID} > ${fileTemp}
fi

# if bc binary is not installed abort
if ! which bc >/dev/null; then
        if [ $intVerbose -eq 0 ]; then
                echo $strScriptName script requires bc to run. Exiting...
        fi
        echo $DATE $strScriptName script requires bc to run. Exiting...  >> $fileLogLoad
        echo "3 $strScriptName - UNKNOWN - script unable to locate bc command dependency"
        exit 2
fi

while getopts ":v" opt; do
  case $opt in
    v)
      echo "Verbose Mode enabled."
      intVerbose=0
      ;;
  esac
done

## MAIN ########################################################################

# same as bc calculations but w/ awk
#awk -v awkLimit=${intLoadRate} -v awkLoad=${intLoad} -v awkProcs=${intProcCount} 'BEGIN{ if ( awkLimit * awkProcs > awkLoad ) {print "OK limit:" awkLimit " Procs:" awkProcs " Load:" awkLoad }}'
#awk -v awkLimit=${intLoadRate} -v awkLoad=${intLoad} -v awkProcs=${intProcCount} 'BEGIN{ if ( awkLimit * awkProcs < awkLoad ) {print "NOT OK limit:" awkLimit " Procs:" awkProcs " Load:" awkLoad }}'

# calculate the allowed load rate using CPU * Cores * intLoadRate using bc
intLoadRateCalc=`echo "scale=5; ${intLoadRate} * ${intProcCount}" | bc -l | xargs printf %.2f`

# DEBUG, comment this out for production use
if [ $intVerbose -eq 0 ]; then
        echo " Variables/Values - intLoadRate: $intLoadRate , intLoad: $intLoad, intCores: $intCores, intProcessors: $intProcessors, intProcCount: $intProcCount, intLoadRateCalc: $intLoadRateCalc"
fi

# use bc to compare the values b/c BASH cannot work with floating point numbers
if (( $(echo "$intLoad > $intLoadRateCalc" |bc -l) )); then
        if [ $intVerbose -eq 0 ]; then
                echo " $DATE - Load of $intLoad exceeds limit of $intLoadRateCalc, or $intLoadRate per CPU for $intProcCount processors. See $fileLogLoad for details."
        fi
        echo $DATE - Load of $intLoad exceeds limit of $intLoadRateCal, or $intLoadRate per CPU for $intProcCount processors >> $fileLogLoad
        # show the PS info for %cpu, %ram, pid, user, long start time, and command
        if [ $OSTYPE == "darwin16" ]; then
                #ps -eo pcpu,pmem,pid,user,lstart,comm -r | head -6 >> $fileLogLoad
                top -n1 >> $fileLogLoad
        else
                #ps -ewo pcpu,pmem,pid,user,lstart,comm --sort=-pcpu | head -6 >> $fileLogLoad
                top -n1 >> $fileLogLoad
        fi
        intMKStatus=1
        strMKStatus=WARNING
else
        if [ $intVerbose -eq 0 ]; then
                echo " $DATE - Load of $intLoad below limit of $intLoadRateCalc, or $intLoadRate per CPU for $intProcCount processors"
        fi
        intMKStatus=0
        strMKStatus=OK
fi

## END #########################################################################

# cleanup the temp file
rm ${fileTemp}

if [ $intVerbose -eq 0 ]; then
        # doesn't work on MacOS
        if [ $OSTYPE != "darwin16" ]; then
                dateEND=$(date +"%s")
                echo end at `date`
                date -u -d "0 $dateEND seconds - $dateSTART seconds" +"%_H hour(s), %_M minute(s), and %_S second(s) elapsed"
        fi
fi
if [ $OSTYPE == "darwin16" ]; then
        strTop5Processes=`ps -ewo comm,pcpu -r | head -6 | tail -5 | sed -e 's/[[:space:]]\{1,\}\([[:digit:]]\{1,\}\.\)/=\1/' -e 's/[[:space:]]\{1,\}/_/g' | tr '\n' ' '`
else
        strTop5Processes=`ps -ew --sort=-pcpu -o comm,pcpu| head -6 | tail -5 | sed -e 's/[[:space:]]\{1,\}\([[:digit:]]\{1,\}\.\)/=\1/' -e 's/[[:space:]]\{1,\}/_/' | tr '\n' ' '`
fi
echo "$intMKStatus $strScriptName - $strMKStatus - $strTop5Processes, Load: $intLoad"
