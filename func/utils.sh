#!/bin/bash

# colors
r_echo() {
  echo -e "\e[31m$1\e[0m"
}

g_echo() {
  echo -e "\e[32m$1\e[0m"
}

y_echo() {
  echo -e "\e[33m$1\e[0m"
}

# print log
logprint() {
    local message="$1"
    echo -e "$message"
    headlog+="$message\n"
}

# check for command existence
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        missing_commands+=("$1")
    fi
}

ProgressBar() {
# credits to https://stackoverflow.c  om/questions/238073/how-to-add-a-progress-bar-to-a-shell-script
# https://github.com/fearside/ProgressBar/
# Teddy Skarin
# Process data
    let _progress=(${1}*100/${2}*100)/100
    let _done=(${_progress}*4)/10
    let _left=40-$_done
# Build progressbar string lengths
    _fill=$(printf "%${_done}s")
    _empty=$(printf "%${_left}s")

# 1.2 Build progressbar strings and print the ProgressBar line
# 1.2.1 Output example:                           
# 1.2.1.1 Progress : [########################################] 100%
printf "\rProgress : [${_fill// /#}${_empty// /-}] ${_progress}%%"

} 
