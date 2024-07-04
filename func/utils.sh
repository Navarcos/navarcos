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
