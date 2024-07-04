#!/bin/bash

# Add additional YAML resources
hAddResource () {
    local releasename=$1
    local chart=$2
    local repourl=$3
    local namespace=$4
    local targetrevision=$5
    shift 5
    local additional=("$@")

    if [ ${#additional[@]} -ne 0 ]; then
        for yaml in ${additional[@]};do
        kubectl apply -f $yaml
            if [ $? != 0 ];then
            echo "$(r_echo [hAddResource] err:) error on apply $yaml"
            exit 1
            else
            echo "$(r_echo [hAddResource] info:) applied $yaml"
            fi
        done
    fi
}

# Get images from Helm templates
hGetImgs () {
    local releasename=$1
    local chart=$2
    local repourl=$3
    local namespace=$4
    local targetrevision=$5
    shift 5
    local values="$@"

    template="helm template $releasename $chart --version $targetrevision --repo $repourl --namespace $namespace"
    echo "" > ./debug.template.yaml
    for val in "${values[@]}"; do
        if [ -f "$val" ]; then
            template="$(echo $template) --values $val"
            echo $template  >> ./debug.template.yaml
            $template | grep '^[[:space:]]*image:' | sed 's/^[[:space:]]*image://'
        else
            $template | grep '^[[:space:]]*image:' | sed 's/^[[:space:]]*image://'
        fi
    done
    # for val in "${values[@]}"; do
    # echo $val
    # done
}

# Install Helm Chart
hInstall () {
    local releasename=$1
    local chart=$2
    local repourl=$3
    local namespace=$4
    local targetrevision=$5
    shift 5
    local values=("$@")

    local helm_cmd="helm upgrade \"$releasename\" \"$chart\" --install --wait --create-namespace --namespace \"$namespace\" --version \"$targetrevision\" --repo \"$repourl\""
    for val in "${values[@]}"; do
        echo "######### Values ######### $val"
        helm_cmd+=" --values \"$val\""
    done
    retry=3
    while [ $retry -gt 0 ];do
        boom=0
        echo $(r_echo "debug: $helm_cmd")
        bash -c "$helm_cmd"
        if [ $? != 0 ];then
            echo "#### bOOm #### : failed, retry"
            let retry-=1
            if [ $retry -eq 0 ];then boom=1; fi
        else
            retry=0
        fi
        if [ $boom -eq 1 ];then
            read -p "[hInstall] something is not working, wanna retry ? q to quit, or anything else to retry:  " RESTART
            if [ "$RESTART" != "q" ];then
                retry=1
                clear
                echo -e "$HEADER"
                echo -e "$headlog"
            else
                exit 1
            fi
        fi
    done
}

# Verify k8s resource existence
hVerResource () {
    local releasename=$1
    local chart=$2
    local repourl=$3
    local namespace=$4
    local targetrevision=$5
    shift 5
    local dependsonobject=("$@")

    if [ ${#dependsonobject[@]} -ne 0 ]; then
        echo "$(r_echo [hVerResource] dependency:) I depend on: ${dependsonobject[@]}"
        for object in ${dependsonobject[@]};do
        echo "checking and wait for existence: $object"
            objectnamespace=$(echo $object | cut -d / -f1)
            objectname=$(echo $object | cut -d / -f3)
            objectkind=$(echo $object | cut -d / -f2)
            objectnamever=""
            while [ "$objectnamever" != "$objectname" ];do
                echo "launching ... kubectl get $objectkind $objectname -n $objectnamespace -o yaml | yq '.metadata.name'"
                objectnamever=$(kubectl get $objectkind $objectname -n $objectnamespace -o yaml | yq '.metadata.name')
                echo "[hVerResource] resource not ready, retry"
                clear
                echo -e "$HEADER"
                echo -e "$headlog"
                sleep 5
            done
        done
    else
        echo "$(r_echo [hVerResource] dependency:) I have no dependencies"
    fi
}

# Verify k8s resource readyness
hVerReady () {
    local releasename=$1
    local chart=$2
    local repourl=$3
    local namespace=$4
    local targetrevision=$5
    shift 5
    local dependsonrelease=("$@")

    if [ ${#dependsonrelease[@]} -ne 0 ]; then
        echo "$(r_echo [hVerReady] dependency:) I depend on:${dependsonrelease[@]}"
        for release in ${dependsonrelease[@]};do
            dependnamespace=$(echo $release | cut -d / -f1)
            dependrelease=$(echo $release | cut -d / -f2)
            #DO SOMETHING TO GET THE RELEASE STATUS
            ready=0
            while [ $ready -eq 0 ];do
                echo "running ... kubectl wait --for=condition=ready pod -n $dependnamespace -l app.kubernetes.io/instance=$dependrelease"
                kubectl wait --for=condition=ready pod -n $dependnamespace -l app.kubernetes.io/name=$dependrelease
                if [ $? != 0 ];then
                    echo "$(r_echo [hVerReady] err:) error on waiting $release"
                    clear
                    echo -e "$HEADER"
                    echo -e "$headlog"
                    sleep 5
                else
                    ready=1
                fi
            done
            sleep 5
        done
    else
        echo "$(r_echo [hVerReady] dependency:) I have no dependencies"
    fi
}
