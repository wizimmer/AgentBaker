#!/bin/bash
{{/* FIPS-related error codes */}}
ERR_UA_TOOLS_INSTALL_TIMEOUT=180 {{/* Timeout waiting for ubuntu-advantage-tools install */}}
ERR_ADD_UA_APT_REPO=181 {{/* Error to add UA apt repository */}}
ERR_AUTO_UA_ATTACH=182 {{/* Error to auto UA attach */}}
ERR_UA_DISABLE_LIVEPATCH=183 {{/* Error to disable UA livepatch */}}
ERR_UA_ENABLE_FIPS=184 {{/* Error to enable UA FIPS */}}
ERR_UA_DETACH=185 {{/* Error to detach UA */}}
ERR_LINUX_HEADER_INSTALL_TIMEOUT=186 {{/* Timeout to install linux header */}}
ERR_STRONGSWAN_INSTALL_TIMEOUT=187 {{/* Timeout to install strongswan */}}

ERR_NTP_INSTALL_TIMEOUT=10 {{/*Unable to install NTP */}}
ERR_NTP_START_TIMEOUT=11 {{/* Unable to start NTP */}}
ERR_STOP_OR_DISABLE_SYSTEMD_TIMESYNCD_TIMEOUT=12 {{/* Timeout waiting for systemd-timesyncd stop */}}
ERR_STOP_OR_DISABLE_NTP_TIMEOUT=13 {{/* Timeout waiting for ntp stop */}}
ERR_CHRONY_INSTALL_TIMEOUT=14 {{/*Unable to install CHRONY */}}
ERR_CHRONY_START_TIMEOUT=15 {{/* Unable to start CHRONY */}}

echo "Sourcing tool_installs_ubuntu.sh"

installAscBaseline() {
   echo "Installing ASC Baseline tools..."
   ASC_BASELINE_TMP=asc-baseline.deb
   retrycmd_if_failure_no_stats 120 5 25 dpkg -i $ASC_BASELINE_TMP || exit $ERR_APT_INSTALL_TIMEOUT
   sudo cp /opt/microsoft/asc-baseline/baselines/oms_audits.xml /opt/microsoft/asc-baseline/oms_audits.xml
   cd /opt/microsoft/asc-baseline
   sudo ./ascbaseline -d .
   sudo ./ascremediate -d . -m all
   sudo ./ascbaseline -d . | grep -B2 -A6 "FAIL"
   cd -
   echo "Check UDF"
   cat /etc/modprobe.d/*.conf | grep udf
   echo "Finished Setting up ASC Baseline"
}

installBcc() {
    echo "Installing BCC tools..."
    wait_for_apt_locks
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    VERSION=$(grep DISTRIB_RELEASE /etc/*-release| cut -f 2 -d "=")
    apt_get_install 120 5 300 build-essential git bison cmake flex  libedit-dev libllvm6.0 llvm-6.0-dev libclang-6.0-dev python zlib1g-dev libelf-dev python3-distutils libfl-dev || exit $ERR_BCC_INSTALL_TIMEOUT
    mkdir -p /tmp/bcc
    pushd /tmp/bcc
    git clone https://github.com/iovisor/bcc.git
    mkdir bcc/build; cd bcc/build
    git checkout v0.24.0
    cmake .. || exit 1
    make
    sudo make install || exit 1
    cmake -DPYTHON_CMD=python3 .. || exit 1 # build python3 binding 
    pushd src/python/
    make
    sudo make install || exit 1
    popd
    popd
    # we explicitly do not remove build-essential or git
    # these are standard packages we want to keep, they should usually be in the final build anyway.
    # only ensuring they are installed above.
    apt list --installed | grep cloud
    apt_get_purge 120 5 300 bison cmake flex libedit-dev libllvm6.0 llvm-6.0-dev libclang-6.0-dev zlib1g-dev libelf-dev libfl-dev || exit $ERR_BCC_INSTALL_TIMEOUT
}

configGPUDrivers() {
    rmmod nouveau
    echo blacklist nouveau >> /etc/modprobe.d/blacklist.conf
    retrycmd_if_failure_no_stats 120 5 25 update-initramfs -u || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    wait_for_apt_locks
    retrycmd_if_failure 30 5 3600 apt-get -o Dpkg::Options::="--force-confold" install -y nvidia-container-runtime="${NVIDIA_CONTAINER_RUNTIME_VERSION}" || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    if [[ "${CONTAINER_RUNTIME}" == "docker" ]]; then
        retrycmd_if_failure 120 5 25 pkill -SIGHUP dockerd || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    else
        retrycmd_if_failure 120 5 25 pkill -SIGHUP containerd || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    fi
    mkdir -p $GPU_DEST/lib64 $GPU_DEST/overlay-workdir
    retrycmd_if_failure 120 5 25 mount -t overlay -o lowerdir=/usr/lib/x86_64-linux-gnu,upperdir=${GPU_DEST}/lib64,workdir=${GPU_DEST}/overlay-workdir none /usr/lib/x86_64-linux-gnu || exit $ERR_GPU_DRIVERS_INSTALL_TIMEOUT
    retrycmd_if_failure 3 1 600 sh $GPU_DEST/nvidia-drivers-$GPU_DV --silent --accept-license --no-drm --dkms --utility-prefix="${GPU_DEST}" --opengl-prefix="${GPU_DEST}" || exit $ERR_GPU_DRIVERS_START_FAIL
    mv ${GPU_DEST}/bin/* /usr/bin
    echo "${GPU_DEST}/lib64" > /etc/ld.so.conf.d/nvidia.conf
    retrycmd_if_failure 120 5 25 ldconfig || exit $ERR_GPU_DRIVERS_START_FAIL
    umount -l /usr/lib/x86_64-linux-gnu
    retrycmd_if_failure 120 5 25 nvidia-modprobe -u -c0 || exit $ERR_GPU_DRIVERS_START_FAIL
    retrycmd_if_failure 120 5 25 nvidia-smi || exit $ERR_GPU_DRIVERS_START_FAIL
    retrycmd_if_failure 120 5 25 ldconfig || exit $ERR_GPU_DRIVERS_START_FAIL
}

disableNtpAndTimesyncdInstallChrony() {
    # Disable systemd-timesyncd
    systemctl_stop 20 30 120 systemd-timesyncd || exit $ERR_STOP_OR_DISABLE_SYSTEMD_TIMESYNCD_TIMEOUT
    systemctl disable systemd-timesyncd || exit $ERR_STOP_OR_DISABLE_SYSTEMD_TIMESYNCD_TIMEOUT

    # Disable ntp if present
    status=$(systemctl show -p SubState --value ntp)
    if [ $status == 'dead' ]; then
        echo "ntp is removed, no need to disable"
    else
        systemctl_stop 20 30 120 ntp || exit $ERR_STOP_OR_DISABLE_NTP_TIMEOUT
        systemctl disable ntp || exit $ERR_STOP_OR_DISABLE_NTP_TIMEOUT
    fi

    # Install chrony
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
    apt_get_install 20 30 120 chrony || exit $ERR_CHRONY_INSTALL_TIMEOUT
    cat > /etc/chrony/chrony.conf <<EOF
# Welcome to the chrony configuration file. See chrony.conf(5) for more
# information about usuable directives.

# This will use (up to):
# - 4 sources from ntp.ubuntu.com which some are ipv6 enabled
# - 2 sources from 2.ubuntu.pool.ntp.org which is ipv6 enabled as well
# - 1 source from [01].ubuntu.pool.ntp.org each (ipv4 only atm)
# This means by default, up to 6 dual-stack and up to 2 additional IPv4-only
# sources will be used.
# At the same time it retains some protection against one of the entries being
# down (compare to just using one of the lines). See (LP: #1754358) for the
# discussion.
#
# About using servers from the NTP Pool Project in general see (LP: #104525).
# Approved by Ubuntu Technical Board on 2011-02-08.
# See http://www.pool.ntp.org/join.html for more information.
#pool ntp.ubuntu.com        iburst maxsources 4
#pool 0.ubuntu.pool.ntp.org iburst maxsources 1
#pool 1.ubuntu.pool.ntp.org iburst maxsources 1
#pool 2.ubuntu.pool.ntp.org iburst maxsources 2

# This directive specify the location of the file containing ID/key pairs for
# NTP authentication.
keyfile /etc/chrony/chrony.keys

# This directive specify the file into which chronyd will store the rate
# information.
driftfile /var/lib/chrony/chrony.drift

# Uncomment the following line to turn logging on.
#log tracking measurements statistics

# Log files location.
logdir /var/log/chrony

# Stop bad estimates upsetting machine clock.
maxupdateskew 100.0

# This directive enables kernel synchronisation (every 11 minutes) of the
# real-time clock. Note that it can’t be used along with the 'rtcfile' directive.
rtcsync

# Settings come from: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/time-sync
refclock PHC /dev/ptp0 poll 3 dpoll -2 offset 0
makestep 1.0 -1
EOF

    systemctlEnableAndStart chrony || exit $ERR_CHRONY_START_TIMEOUT
}

installFIPS() {
    echo "Installing FIPS..."
    wait_for_apt_locks

    echo "adding ua repository..."
    retrycmd_if_failure 5 10 120 add-apt-repository -y ppa:ua-client/stable || exit $ERR_ADD_UA_APT_REPO
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT

    echo "installing ua tools..."
    apt_get_install 5 10 120 ubuntu-advantage-tools || exit $ERR_UA_TOOLS_INSTALL_TIMEOUT

    echo "auto attaching ua..."
    retrycmd_if_failure 5 10 120 ua auto-attach || exit $ERR_AUTO_UA_ATTACH

    echo "disabling ua livepatch..."
    retrycmd_if_failure 5 10 300 echo y | ua disable livepatch

    echo "enabling ua fips-updates..."
    retrycmd_if_failure 5 10 1200 echo y | ua enable fips-updates || exit $ERR_UA_ENABLE_FIPS

    # 'ua status' for logging
    ua status
    # new 'ua detach' removes fips-updates kernel entry from grub.cfg, backup it
    cp -f /boot/grub/grub.cfg /tmp/

    # now the fips packages/kernel are installed, clean up apt settings in the vhd,
    # the VMs created on customers' subscriptions don't have access to UA repo
    echo "detaching ua..."
    retrycmd_if_failure 5 10 120 ua detach --assume-yes || $ERR_UA_DETACH
    mv -f /tmp/grub.cfg /boot/grub/
    echo "removing ua tools..."
    apt_get_purge 5 10 120 ubuntu-advantage-tools
    rm -f /etc/apt/trusted.gpg.d/ua-client_ubuntu_stable.gpg
    rm -f /etc/apt/trusted.gpg.d/ubuntu-advantage-esm-apps.gpg
    rm -f /etc/apt/trusted.gpg.d/ubuntu-advantage-esm-infra-trusty.gpg
    rm -f /etc/apt/trusted.gpg.d/ubuntu-advantage-fips.gpg
    rm -f /etc/apt/sources.list.d/ua-client-ubuntu-stable-bionic.list
    rm -f /etc/apt/sources.list.d/ubuntu-esm-apps.list
    rm -f /etc/apt/sources.list.d/ubuntu-esm-infra.list
    rm -f /etc/apt/sources.list.d/ubuntu-fips.list
    rm -f /etc/apt/auth.conf.d/80ubuntu-advantage
    apt_get_update || exit $ERR_APT_UPDATE_TIMEOUT
}

relinkResolvConf() {
    # /run/systemd/resolve/stub-resolv.conf contains local nameserver 127.0.0.53
    # remove this block after toggle disable-1804-systemd-resolved is enabled prod wide
    resolvconf=$(readlink -f /etc/resolv.conf)
    if [[ "${resolvconf}" == */run/systemd/resolve/stub-resolv.conf ]]; then
        unlink /etc/resolv.conf
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
}

listInstalledPackages() {
    apt list --installed
}
