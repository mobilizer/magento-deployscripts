#!/bin/bash

VALID_ENVIRONMENTS=" production staging devbox latest deploy integration stage "

# OS X compatibility (greadlink, gsed, zcat are GNU implementations for OS X)
[[ `uname` == 'Darwin' ]] && {
	which greadlink gsed gzcat > /dev/null && {
		unalias readlink sed zcat
		alias readlink=greadlink sed=gsed zcat=gzcat
	} || {
		echo 'ERROR: GNU coreutils required for Mac. Try: brew install coreutils gnu-sed'
		exit 1
	}
}

MY_PATH=`dirname $(readlink -f "$0")`
RELEASEFOLDER=$(readlink -f "${MY_PATH}/../../..")

function usage {
    echo "Usage:"
    echo " $0 -e <environment> [-r <releaseFolder>] [-i <SystemStoragePath>] [-s]"
    echo " -e Environment (e.g. production, staging, devbox,...)"
    echo " -i Systemstorage root path or SSH URI"
    echo " -s If set the systemstorage will not be imported"
    echo ""
    exit $1
}

while getopts 'e:r:i:s' OPTION ; do
case "${OPTION}" in
        e) ENVIRONMENT="${OPTARG}";;
        r) RELEASEFOLDER=`echo "${OPTARG}" | sed -e "s/\/*$//" `;; # delete last slash
        i) SYSTEMSTORAGEPATH=`echo "${OPTARG}" | sed -e "s/\/*$//" `;; # delete last slash
        s) SKIPIMPORTFROMSYSTEMSTORAGE=true;;
        \?) echo; usage 1;;
    esac
done

if [[ ! "${RELEASEFOLDER}" = /* ]] ; then RELEASEFOLDER=`cd "${RELEASEFOLDER}"; pwd` ; fi # convert relative to absolute path
echo
echo "Release Folder: ${RELEASEFOLDER}"

if [ ! -f "${RELEASEFOLDER}/htdocs/index.php" ] ; then echo "Invalid release folder" ; exit 1; fi
if [ ! -f "${RELEASEFOLDER}/tools/n98-magerun.phar" ] ; then echo "Could not find n98-magerun.phar" ; exit 1; fi
if [ ! -f "${RELEASEFOLDER}/tools/zettr.phar" ] ; then echo "Could not find tools/zettr.phar" ; exit 1; fi
if [ ! -f "${RELEASEFOLDER}/Configuration/settings.csv" ] ; then echo "Could not find settings.csv" ; exit 1; fi

# Checking environment
if [ -z "${ENVIRONMENT}" ]; then echo "ERROR: Please provide an environment code (e.g. -e staging)"; exit 1; fi
if [[ "${VALID_ENVIRONMENTS}" =~ " ${ENVIRONMENT} " ]] ; then
    echo "Environment: ${ENVIRONMENT}"
else
    echo "ERROR: Illegal environment code" ; exit 1;
fi


echo
echo "Linking to shared directories"
echo "-----------------------------"
if [[ -n ${SKIPSHAREDFOLDERCONFIG} ]]  && ${SKIPSHAREDFOLDERCONFIG} ; then
    echo "Skipping shared directory config because parameter was set"
else
    SHAREDFOLDER="${RELEASEFOLDER}/../shared"
	if [ ! -d "${SHAREDFOLDER}" ] ; then
    	echo "Could not find '../shared'. Trying '../../shared' now"
    	SHAREDFOLDER="${RELEASEFOLDER}/../../shared";
	fi
	if [ ! -d "${SHAREDFOLDER}" ] ; then
    	echo "Could not find '../../shared'. Trying '../../../shared' now"
    	SHAREDFOLDER="${RELEASEFOLDER}/../../../shared";
	fi

    if [ ! -d "${SHAREDFOLDER}" ] ; then echo "Shared directory ${SHAREDFOLDER} not found"; exit 1; fi
    if [ ! -d "${SHAREDFOLDER}/media" ] ; then echo "Shared directory ${SHAREDFOLDER}/media not found"; exit 1; fi
    if [ ! -d "${SHAREDFOLDER}/var" ] ; then echo "Shared directory ${SHAREDFOLDER}/var not found"; exit 1; fi

	if [ -h "${RELEASEFOLDER}/htdocs/media" ]; then echo "Found existing media folder symlink. Removing."; rm "${RELEASEFOLDER}/htdocs/media"; fi
	if [ -d "${RELEASEFOLDER}/htdocs/media" ]; then echo "Found existing media folder that shouldn't be there"; exit 1; fi
	if [ -h "${RELEASEFOLDER}/htdocs/var" ]; then echo "Found existing var folder symlink. Removing."; rm "${RELEASEFOLDER}/htdocs/var"; fi
	if [ -d "${RELEASEFOLDER}/htdocs/var" ]; then echo "Found existing var folder that shouldn't be there"; exit 1; fi

    echo "Setting symlink (${RELEASEFOLDER}/htdocs/media) to shared media folder (${SHAREDFOLDER}/media)"
    ln -s "${SHAREDFOLDER}/media" "${RELEASEFOLDER}/htdocs/media"  || { echo "Error while linking to shared media directory" ; exit 1; }

    echo "Setting symlink (${RELEASEFOLDER}/htdocs/var) to shared var folder (${SHAREDFOLDER}/var)"
    ln -s "${SHAREDFOLDER}/var" "${RELEASEFOLDER}/htdocs/var"  || { echo "Error while linking to shared var directory" ; exit 1; }
fi


echo
echo "Running modman"
echo "--------------"
cd "${RELEASEFOLDER}" || { echo "Error while switching to release directory" ; exit 1; }
tools/modman deploy-all --force || { echo "Error while running modman" ; exit 1; }

echo
echo "Apply magento patch via modman --copy"
echo "--------------"
tools/modman deploy --force --copy magento_patches || { echo "Error while applying Magento patches. Expects module magento_patches." ; }


echo
echo "Systemstorage"
echo "-------------"
if [[ -n ${SKIPIMPORTFROMSYSTEMSTORAGE} ]]  && ${SKIPIMPORTFROMSYSTEMSTORAGE} ; then
    echo "Skipping import system storage backup because parameter was set"
else

    if [ -z "${MASTER_SYSTEM}" ] ; then
        if [ ! -f "${RELEASEFOLDER}/Configuration/mastersystem.txt" ] ; then echo "Could not find mastersystem.txt"; exit 1; fi
        MASTER_SYSTEM=`cat ${RELEASEFOLDER}/Configuration/mastersystem.txt`
        if [ -z "${MASTER_SYSTEM}" ] ; then echo "Error reading master system"; exit 1; fi
    fi

    if [ "${MASTER_SYSTEM}" == "${ENVIRONMENT}" ] ; then
        echo "Current environment is the master environment. Skipping import."
    else
        echo "Current environment (${ENVIRONMENT}) is not the master environment (${MASTER_SYSTEM}). Importing system storage..."
        if [ -z "${SYSTEMSTORAGEPATH}" ] ; then echo "Systemstorage path ${SYSTEMSTORAGEPATH} not found"; exit 1; fi
        echo "from systemstorage root path: ${SYSTEMSTORAGEPATH}"

        if [ -z "${PROJECT}" ] ; then
            if [ ! -f "${RELEASEFOLDER}/Configuration/project.txt" ] ; then echo "Could not find project.txt"; exit 1; fi
            PROJECT=`cat ${RELEASEFOLDER}/Configuration/project.txt`
            if [ -z "${PROJECT}" ] ; then echo "Error reading project name"; exit 1; fi
        fi

        # Apply db settings
        cd "${RELEASEFOLDER}/htdocs" || { echo "Error while switching to htdocs directory" ; exit 1; }
        ../tools/zettr.phar apply "${ENVIRONMENT}" ../Configuration/settings.csv --groups db || { echo "Error while applying db settings" ; exit 1; }


        # Import systemstorage
        ../tools/systemstorage_import.sh -p "${RELEASEFOLDER}/htdocs/" -s "${SYSTEMSTORAGEPATH}/${PROJECT}/backup/${MASTER_SYSTEM}" || { echo "Error while importing systemstorage"; exit 1; }
    fi

fi


echo
echo "Applying settings"
echo "-----------------"
cd "${RELEASEFOLDER}/htdocs" || { echo "Error while switching to htdocs directory" ; exit 1; }
if [ -f ../Configuration/settings.csv ]; then
    ../tools/zettr.phar apply ${ENVIRONMENT} ../Configuration/settings.csv --groups db || { echo "Error while applying database settings" ; exit 1; }
    ../tools/zettr.phar apply ${ENVIRONMENT} ../Configuration/settings.csv || { echo "Error while applying settings" ; exit 1; }
else
    echo "No Configuration/settings.csv found!"
fi
echo



if [ -f "${RELEASEFOLDER}/htdocs/shell/aoe_classpathcache.php" ] ; then
    echo
    echo "Setting revalidate class path cache flag (Aoe_ClassPathCache)"
    echo "-------------------------------------------------------------"
    cd "${RELEASEFOLDER}/htdocs/shell" || { echo "Error while switching to htdocs/shell directory" ; exit 1; }
    php aoe_classpathcache.php -action setRevalidateFlag || { echo "Error while revalidating Aoe_ClassPathCache" ; exit 1; }
fi



echo
echo "Triggering Magento setup scripts via n98-magerun"
echo "------------------------------------------------"
cd -P "${RELEASEFOLDER}/htdocs/" || { echo "Error while switching to htdocs directory" ; exit 1; }
../tools/n98-magerun.phar sys:setup:run || { echo "Error while triggering the update scripts using n98-magerun" ; exit 1; }



# Cache should be handled by customizing the id_prefix!
#echo
#echo "Cache"
#echo "-----"
#
#if [ "${ENVIRONMENT}" == "devbox" ] || [ "${ENVIRONMENT}" == "latest" ] || [ "${ENVIRONMENT}" == "deploy" ] ; then
#    cd -P "${RELEASEFOLDER}/htdocs/" || { echo "Error while switching to htdocs directory" ; exit 1; }
#    ../tools/n98-magerun.phar cache:flush || { echo "Error while flushing cache using n98-magerun" ; exit 1; }
#    ../tools/n98-magerun.phar cache:enable || { echo "Error while enabling cache using n98-magerun" ; exit 1; }
#fi


if [ -f "${RELEASEFOLDER}/htdocs/maintenance.flag" ] ; then
    echo
    echo "Deleting maintenance.flag"
    echo "-------------------------"
    rm "${RELEASEFOLDER}/htdocs/maintenance.flag" || { echo "Error while deleting the maintenance.flag" ; exit 1; }
fi

echo
echo "Successfully completed installation."
echo
