#!/bin/bash
# Check for sysctls values needed by docker clusters

check_sysctl() {
    NAVARCOS_DOCKER_SYSCTL="0"
    if [ $(sysctl -b fs.inotify.max_user_watches) -lt "1048576" ]; then
        echo "$(r_echo NAVARCOS:ERR:) Sysctl fs.inotify.max_user_watches is less than 1048576"
        echo "$(r_echo NAVARCOS:ERR:) Please 'sudo sysctl fs.inotify.max_user_watches=1048576'"
        NAVARCOS_DOCKER_SYSCTL="1"
    fi
    if [ $(sysctl -b fs.inotify.max_user_instances) -lt "8192" ]; then
        echo "$(r_echo NAVARCOS:ERR:) Sysctl fs.inotify.max_user_instances is less than 8192"
        echo "$(r_echo NAVARCOS:ERR:) Please 'sudo sysctl fs.inotify.max_user_instances=8192'"
        NAVARCOS_DOCKER_SYSCTL="1"
    fi
    if [ ${NAVARCOS_DOCKER_SYSCTL} -eq "1" ]; then
        echo "$(r_echo NAVARCOS:ERR:) Sysctl values not compatible with Docker clusters"
        exit 1
    fi
    echo "$(g_echo NAVARCOS:INFO:) Sysctl fs.inotify.max_user_watches is $(sysctl -b fs.inotify.max_user_watches)"
    echo "$(g_echo NAVARCOS:INFO:) Sysctl fs.inotify.max_user_instances is $(sysctl -b fs.inotify.max_user_instances)"
}
