#!/bin/bash

function nodesnumvalidator () {
if  ! [[ $1 =~ ^[0-9]+$ ]] || [ $1 -lt 1 ]; then
  echo "not valid! only 0-9 and >0"
  return 1
fi
return 0
}

function namingvalidator () {
if ! [[ $1 =~ ^[a-z0-9-]+$ ]] ; then
  echo "not valid! lowercase, only a-z 0-9 and '-'"
  return 1
fi
return 0
}

function readValidator() {
  local prompt_message=$1
  local validation_function=$2
  local input_variable_name=$3
  local input_value

  while true; do
    read -p "$prompt_message" input_value
    $validation_function $input_value
    if [ $? -eq 0 ]; then
      eval $input_variable_name=\$input_value 
      break
    else
      echo "Please enter a valid value."
    fi
  done
}