#!/bin/bash

if [ -z "$1" ]
  then
    echo "No argument supplied"
    exit
fi

kubectl -n plancia create serviceaccount "${1}"

kubectl create rolebinding plancia-admin-token --namespace plancia \
  --clusterrole=cluster-admin \
  --serviceaccount=plancia:"${1}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: "plancia-admin-token-${1}"
  namespace: "plancia"
  annotations:
    kubernetes.io/service-account.name: "${1}"
type: kubernetes.io/service-account-token
EOF
