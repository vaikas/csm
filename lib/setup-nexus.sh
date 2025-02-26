#!/usr/bin/env bash

# Copyright 2021 Hewlett Packard Enterprise Development LP

set -exo pipefail

ROOTDIR="$(dirname "${BASH_SOURCE[0]}")/.."
source "${ROOTDIR}/lib/version.sh"
source "${ROOTDIR}/lib/install.sh"

# Check for required resources for Nexus setup
nexus_resources_ready=0
counter=1
counter_max=10
sleep_time=30
url=packages.local

while [[ $nexus_resources_ready -eq 0 ]] && [[ "$counter" -le "$counter_max" ]]; do
    nexus_check_configmap=$(kubectl -n services get cm cray-dns-unbound -o json 2>&1 | jq '.binaryData."records.json.gz"' -r 2>&1 | base64 -d 2>&1| gunzip - 2>&1|jq 2>&1|grep $url|wc -l)
    nexus_check_dns=$(dig $url +short |wc -l)
    nexus_check_pod=$(kubectl get pods -n nexus| grep nexus | grep -v Completed | awk {' print $3 '})

    if [[ "$nexus_check_dns" -eq "1" ]] && [[ "$nexus_check_pod" == "Running" ]]; then
        echo "$url is in dns."
        echo "Nexus pod $nexus_check_pod."
        echo "Moving forward with Nexus setup."
        nexus_resources_ready=1
    fi
    if [[ "$nexus_check_pod" != "Running" ]]; then
        echo "Nexus pod not ready yet."
        echo "Nexus pod status is: $nexus_check_pod."
    fi

    if [[ "$nexus_check_dns" -eq "0" ]]; then
        echo "$url is not in DNS yet."
        if [ "$nexus_check_configmap" -lt "1" ]; then
            echo "$url is not loaded into unbound configmap yet."
            echo "Waiting for DNS and nexus pod to be ready. Retry in $sleep_time seconds. Try $counter out of $counter_max."
        fi
    fi
    if [[ "$counter" -eq "$counter_max" ]]; then
        echo "Max number of checks reached, exiting."
        echo "Please check the status of nexus, cray-dns-unbound and cray-sls."
        exit 1
    fi
    ((counter++))
done

# Set podman --dns flags to unbound IP
podman_run_flags+=(--dns "$(kubectl get -n services service cray-dns-unbound-udp-nmn -o jsonpath='{.status.loadBalancer.ingress[0].ip}')")

load-install-deps

# Setup Nexus
nexus-setup blobstores   "${ROOTDIR}/nexus-blobstores.yaml"
nexus-setup repositories "${ROOTDIR}/nexus-repositories.yaml"

# Upload assets to existing repositories
skopeo-sync "${ROOTDIR}/docker"
# XXX For backwards compatibilty with CSM 1.0, container images under
# XXX dtr.dev.cray.com and quay.io are also uploaded to the root of
# XXX registry.local. This is only necessary while charts and procedures still
# XXX reference dtr.dev.cray.com or quay.io/skopeo/stable:latest.
[[ -d "${ROOTDIR}/docker/dtr.dev.cray.com" ]] && skopeo-sync "${ROOTDIR}/docker/dtr.dev.cray.com"
[[ -d "${ROOTDIR}/docker/quay.io" ]] && podman run --rm "${podman_run_flags[@]}" -v "$(realpath "${ROOTDIR}/docker/quay.io"):/image:ro" "$SKOPEO_IMAGE" copy --dest-tls-verify=false dir:/image/skopeo/stable:latest "docker://${NEXUS_REGISTRY:="registry.local"}/skopeo/stable:latest"

nexus-upload helm "${ROOTDIR}/helm" "${CHARTS_REPO:-"charts"}"

# Upload repository contents
nexus-upload raw "${ROOTDIR}/rpm/cray/csm/sle-15sp2"         "csm-${RELEASE_VERSION}-sle-15sp2"
nexus-upload raw "${ROOTDIR}/rpm/cray/csm/sle-15sp2-compute" "csm-${RELEASE_VERSION}-sle-15sp2-compute"
nexus-upload raw "${ROOTDIR}/rpm/shasta-firmware"            "shasta-firmware-${RELEASE_VERSION}"

clean-install-deps

set +x
cat >&2 <<EOF
+ Nexus setup complete
setup-nexus.sh: OK
EOF
