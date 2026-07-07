#!/usr/bin/env bash
# SPDX-license-identifier: Apache-2.0
##############################################################################
# Copyright (c) 2023-2025 The Nephio Authors.
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################

set -o pipefail
set -o errexit
set -o nounset

# get_status() - Print the current status of the management cluster
function get_status {
    set +o xtrace
    if [ -f /proc/stat ]; then
        printf "CPU usage: "
        grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage " %"}'
    fi
    if [ -f /proc/pressure/io ]; then
        printf "I/O Pressure Stall Information (PSI): "
        grep full /proc/pressure/io | awk '{ sub(/avg300=/, ""); print $4 }'
    fi
    if [ -f /proc/zoneinfo ]; then
        printf "Memory free(Kb):"
        awk -v low="$(grep low /proc/zoneinfo | awk '{k+=$2}END{print k}')" '{a[$1]=$2}  END{ print a["MemFree:"]+a["Active(file):"]+a["Inactive(file):"]+a["SReclaimable:"]-(12*low);}' /proc/meminfo
    fi
    printf "Disk usage: "
    sudo df -h
    if command -v docker >/dev/null; then
        echo "Docker statistics:"
        docker stats --no-stream
        docker ps --size
    fi
    if [ -f /tmp/e2e_dmesg_base.log ]; then
        echo "Kernel diagnostic messages:"
        sudo dmesg >/tmp/e2e_dmesg_current.log
        diff /tmp/e2e_dmesg_base.log /tmp/e2e_dmesg_current.log
    fi
    if command -v kubectl >/dev/null; then
        echo "Draft Porch Package Revisions"
        kubectl get packagerevision -o jsonpath='{range .items[?(@.spec.lifecycle=="Draft")]}{.metadata.name}{"\n"}{end}' || :
        KUBECONFIG=$HOME/.kube/config
        for kubeconfig in /tmp/*-kubeconfig; do
            KUBECONFIG+=":$kubeconfig"
        done
        export KUBECONFIG
        for context in $(kubectl config get-contexts --no-headers --output name); do
            echo "Kubernetes Events ($context):"
            kubectl get events --sort-by='.lastTimestamp' -A --context "$context" --field-selector type!=Normal
            echo "Kubernetes Resources ($context):"
            kubectl get all -A -o wide --context "$context"
        done
    fi
}

function get_metadata {
    local md=$1
    local df=$2

    curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$md" -H "Metadata-Flavor: Google" || echo "$df"
}

export DEBUG=${NEPHIO_DEBUG:-$(get_metadata nephio-setup-debug "false")}

[[ $DEBUG != "true" ]] || set -o xtrace

RUN_E2E=${NEPHIO_RUN_E2E:-$(get_metadata nephio-run-e2e "false")}
REPO=${NEPHIO_REPO:-$(get_metadata nephio-test-infra-repo "https://github.com/nephio-project/test-infra.git")}
BRANCH=${NEPHIO_BRANCH:-$(get_metadata nephio-test-infra-branch "main")}
NEPHIO_USER=${NEPHIO_USER:-$(get_metadata nephio-user "${USER:-ubuntu}")}
NEPHIO_CATALOG_REPO_URI=${NEPHIO_CATALOG_REPO_URI:-$(get_metadata nephio-catalog-repo-uri "https://github.com/nephio-project/catalog.git")}
NEPHIO_PORCH_IMAGE_TAG=${NEPHIO_PORCH_IMAGE_TAG:-v1.5.9}
K8S_CONTEXT=${K8S_CONTEXT:-"kind-kind"}
K8S_VERSION=${K8S_VERSION:-"v1.32.0"}
HOME=${NEPHIO_HOME:-/home/$NEPHIO_USER}
REPO_DIR=${NEPHIO_REPO_DIR:-$HOME/test-infra}
DOCKERHUB_USERNAME=${DOCKERHUB_USERNAME:-""}
DOCKERHUB_TOKEN=${DOCKERHUB_TOKEN:-""}
FAIL_FAST=${FAIL_FAST:-$(get_metadata fail_fast "false")}
# MGMT_CLUSTER_TYPE is intended to be set by prow jobs
MGMT_CLUSTER_TYPE=${MGMT_CLUSTER_TYPE:-$(get_metadata mgmt_cluster_type "kind")}

if [ ${MGMT_CLUSTER_TYPE} == "kubeadm" ]; then
    K8S_CONTEXT="kubernetes-admin@kubernetes"
fi
export ANSIBLE_CMD_EXTRA_VAR_LIST='{ "nephio_catalog_repo_uri": "'${NEPHIO_CATALOG_REPO_URI}'", "k8s": { "context" : "'${K8S_CONTEXT}'", "version" : "'$K8S_VERSION'" } }'

if [ ${K8S_CONTEXT} == "kind-kind" ]; then
    export ANSIBLE_TAG=all
else
    export ANSIBLE_TAG=nonkind_k8s
fi

echo "$DEBUG, $RUN_E2E, $REPO, $BRANCH, $NEPHIO_USER, $HOME, $REPO_DIR, $DOCKERHUB_USERNAME, $DOCKERHUB_TOKEN, $ANSIBLE_TAG, $ANSIBLE_CMD_EXTRA_VAR_LIST $K8S_CONTEXT $MGMT_CLUSTER_TYPE"
trap get_status ERR

# Validate root permissions for current user and NEPHIO_USER
if ! sudo -n "true"; then
    echo ""
    echo "Passwordless sudo is needed for '$(id -nu)' user."
    echo "Please fix your /etc/sudoers file. You likely want an"
    echo "entry like the following one..."
    echo ""
    echo "$(id -nu) ALL=(ALL) NOPASSWD: ALL"
    exit 1
fi

if ! sudo -u "$NEPHIO_USER" sudo -n "true"; then
    echo ""
    echo "Passwordless sudo is needed for '$(sudo -u "$NEPHIO_USER" id -nu)' user."
    echo "Please fix your /etc/sudoers file. You likely want an"
    echo "entry like the following one..."
    echo ""
    echo "$(sudo -u "$NEPHIO_USER" id -nu) ALL=(ALL) NOPASSWD: ALL"
    exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
    echo ""
    echo "This script must to be executed by the root user."
    echo ""
    exit 1
fi

if [[ $(sudo -u "$NEPHIO_USER" id -u) -eq 0 ]]; then
    echo ""
    echo "NEPHIO_USER cannot be root (user '$(sudo -u "$NEPHIO_USER" id -nu)')."
    echo ""
    exit 1
fi

if ! command -v git >/dev/null; then
    source /etc/os-release || source /usr/lib/os-release
    case ${ID,,} in
    ubuntu | debian)
        # Removed the damaged list
        rm -rvf /var/lib/apt/lists/*
        apt-get update
        apt-get install -y git
        ;;
    rhel | centos | fedora | rocky)
        PKG_MANAGER=$(command -v dnf || command -v yum)
        $PKG_MANAGER install git -y
        ;;
    *)
        echo "OS not supported"
        exit
        ;;
    esac
fi

if [ ! -d "$REPO_DIR" ]; then
    runuser -u "$NEPHIO_USER" git clone "$REPO" "$REPO_DIR"
    if [[ $BRANCH != "main" ]]; then
        pushd "$REPO_DIR" >/dev/null
        TAG=$(runuser -u "$NEPHIO_USER" -- git tag --list $BRANCH)
        if [[ $TAG == $BRANCH ]]; then
            runuser -u "$NEPHIO_USER" -- git checkout --detach "$TAG"
        else
            runuser -u "$NEPHIO_USER" -- git checkout -b "$BRANCH" --track "origin/$BRANCH"
        fi
        popd >/dev/null
    fi
fi
find "$REPO_DIR" -name '*.sh' -exec chmod +x {} \;

cp "$REPO_DIR/e2e/provision/bash_config.sh" "$HOME/.bash_aliases"
chown "$NEPHIO_USER:$NEPHIO_USER" "$HOME/.bash_aliases"

# Sandbox Creation
int_start=$(date +%s)
cd "$REPO_DIR/e2e/provision"

# === [Kind image preload: keep catalog-pinned image names available] ===
cat << 'EOF' > /tmp/nephio-kind-image-preload.yml
---
- name: Define image replacements for unsupported pinned tags
  ansible.builtin.set_fact:
    nephio_image_mappings:
      - source: bitnami/kube-rbac-proxy:latest
        target: gcr.io/kubebuilder/kube-rbac-proxy:v0.8.0
      - source: docker.io/bitnami/memcached:latest
        target: docker.io/bitnami/memcached:1.6.19-debian-11-r7
      - source: docker.io/bitnami/memcached:latest
        target: docker.io/bitnamilegacy/memcached:1.6.19-debian-11-r7
      - source: docker.io/bitnami/postgresql:latest
        target: docker.io/bitnami/postgresql:15.2.0-debian-11-r26
      - source: docker.io/bitnami/postgresql:latest
        target: docker.io/bitnamilegacy/postgresql:15.2.0-debian-11-r26
      - source: docker.io/bitnami/mongodb:latest
        target: docker.io/bitnami/mongodb:4.4.4-debian-10-r0
      - source: docker.io/bitnami/mongodb:latest
        target: docker.io/bitnamilegacy/mongodb:4.4.4-debian-10-r0
      - source: bitnami/kubectl:latest
        target: bitnami/kubectl:1.32.0
      - source: docker.io/nephio/porch-function-runner:__NEPHIO_PORCH_IMAGE_TAG__
        target: docker.io/nephio/porch-function-runner:latest
      - source: docker.io/nephio/porch-wrapper-server:__NEPHIO_PORCH_IMAGE_TAG__
        target: docker.io/nephio/porch-wrapper-server:latest
      - source: docker.io/nephio/porch-server:__NEPHIO_PORCH_IMAGE_TAG__
        target: docker.io/nephio/porch-server:latest
      - source: docker.io/nephio/porch-controllers:__NEPHIO_PORCH_IMAGE_TAG__
        target: docker.io/nephio/porch-controllers:latest

- name: Pull replacement images
  become: true
  ansible.builtin.command: "docker pull {{ item.source }}"
  loop: "{{ nephio_image_mappings }}"
  register: nephio_image_pull
  until: nephio_image_pull is not failed
  retries: 3
  delay: 10
  changed_when: false

- name: Tag replacement images with catalog-pinned names
  become: true
  ansible.builtin.command: "docker tag {{ item.source }} {{ item.target }}"
  loop: "{{ nephio_image_mappings }}"
  changed_when: false

- name: Import catalog-pinned images into kind containerd
  become: true
  ansible.builtin.shell: "docker save {{ item.target }} | docker exec -i kind-control-plane ctr -n k8s.io images import -"
  loop: "{{ nephio_image_mappings }}"
  changed_when: false

- name: Verify catalog-pinned images are present in kind containerd
  become: true
  ansible.builtin.shell: "docker exec kind-control-plane ctr -n k8s.io images ls | grep -F -- {{ item.target }}"
  loop: "{{ nephio_image_mappings }}"
  changed_when: false
EOF
sed -i "s/__NEPHIO_PORCH_IMAGE_TAG__/$NEPHIO_PORCH_IMAGE_TAG/g" /tmp/nephio-kind-image-preload.yml

BOOTSTRAP_TASKS="playbooks/roles/bootstrap/tasks/main.yml"
if ! grep -q "Preload catalog-pinned images into kind" "$BOOTSTRAP_TASKS"; then
    tmpfile="$(mktemp)"
    awk '
        /- name: Apply kpt packages/ && ! inserted {
            print "- name: Preload catalog-pinned images into kind"
            print "  ansible.builtin.include_tasks: /tmp/nephio-kind-image-preload.yml"
            print "  when: kind.enabled"
            print ""
            inserted = 1
        }
        { print }
    ' "$BOOTSTRAP_TASKS" > "$tmpfile"
    mv "$tmpfile" "$BOOTSTRAP_TASKS"
    chown "$NEPHIO_USER:$NEPHIO_USER" "$BOOTSTRAP_TASKS"
    chmod 644 "$BOOTSTRAP_TASKS"
fi

KPT_TASKS="playbooks/roles/kpt/tasks/main.yml"
if grep -q "Rewrite stale catalog image references" "$KPT_TASKS"; then
    tmpfile="$(mktemp)"
    awk '
        /- name: "Rewrite stale catalog image references: {{ pkg }}"/ {
            skip = 3
            next
        }
        skip > 0 {
            skip--
            next
        }
        { print }
    ' "$KPT_TASKS" > "$tmpfile"
    mv "$tmpfile" "$KPT_TASKS"
    chown "$NEPHIO_USER:$NEPHIO_USER" "$KPT_TASKS"
    chmod 644 "$KPT_TASKS"
fi

# === [Kind image preload end] ===

export DEBUG DOCKERHUB_USERNAME DOCKERHUB_TOKEN FAIL_FAST MGMT_CLUSTER_TYPE K8S_VERSION
runuser -u "$NEPHIO_USER" ./install_sandbox.sh
printf "%s secs\n" "$(($(date +%s) - int_start))"

if [[ $RUN_E2E == "true" && $MGMT_CLUSTER_TYPE == "kind" ]]; then
    runuser -u "$NEPHIO_USER" "$REPO_DIR/e2e/e2e.sh"
fi

echo "Done Nephio Execution"
