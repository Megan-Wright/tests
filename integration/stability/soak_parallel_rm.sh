#!/bin/bash
#
# Copyright (c) 2017-2018, 2020 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# This test will run a number of parallel containers, and then try to
# 'rm -f' them all at the same time. It will check after each run and
# rm that we have the expected number of containers, shims,
# qemus and runtimes active
# The goals are two fold:
# - spot any stuck or non-started components
# - catch any hang ups

cidir=$(dirname "$0")
source "${cidir}/../../metrics/lib/common.bash"
source "/etc/os-release" || source "/usr/lib/os-release"

# How many times will we run the test loop...
ITERATIONS="${ITERATIONS:-5}"

# the system 'free available' level where we stop running the tests, as otherwise
#  the system can crawl to a halt, and/or start refusing to launch new VMs anyway
# We choose 2G, as that is one of the default VM sizes for Kata
MEM_CUTOFF="${MEM_CUTOFF:-(2*1024*1024*1024)}"

# do we need a command argument for this payload?
COMMAND="${COMMAND:-tail -f /dev/null}"

# Runtime path
RUNTIME_PATH=$(command -v $RUNTIME)

# The place where virtcontainers keeps its active pod info
# This is ultimately what 'kata-runtime list' uses to get its info, but
# we can also check it for sanity directly
VC_POD_DIR="${VC_POD_DIR:-/run/vc/sbs}"

# let's cap the test. If you want to run until you hit the memory limit
# then just set this to a very large number
MAX_CONTAINERS="${MAX_CONTAINERS:-110}"

KATA_HYPERVISOR="${KATA_HYPERVISOR:-qemu}"

check_vsock_active() {
	vsock_configured=$($RUNTIME_PATH kata-env | awk '/UseVSock/ {print $3}')
	vsock_supported=$($RUNTIME_PATH kata-env | awk '/SupportVSock/ {print $3}')
	if [ "$vsock_configured" == true ] && [ "$vsock_supported" == true ]; then
		return 0
	else
		return 1
	fi
}

count_containers() {
	sudo ctr c list -q | wc -l
}

check_all_running() {
	local goterror=0

	echo "Checking ${how_many} containers have all relevant components"

	# check what docker thinks
	how_many_running=$(count_containers)

	if (( ${how_many_running} != ${how_many} )); then
		echo "Wrong number of containers running (${how_many_running} != ${how_many}) - stopping"
		((goterror++))
	fi

	# Only check for Kata components if we are using a Kata runtime
	if (( $check_kata_components )); then

		# check we have the right number of shims
		how_many_shims=$(pgrep -a -f ${SHIM_PATH} | grep containerd.sock | wc -l)
		# one shim process per container...
		if (( ${how_many_running} != ${how_many_shims} )); then
			echo "Wrong number of shims running (${how_many_running} != ${how_many_shims}) - stopping"
			((goterror++))
		fi

		# check we have the right number of vm's
		how_many_vms=$(pgrep -a $(basename ${HYPERVISOR_PATH} | cut -d '-' -f1) | wc -l)
		if (( ${how_many_running} != ${how_many_vms} )); then
			echo "Wrong number of $KATA_HYPERVISOR running (${how_many_running} != ${how_many_vms}) - stopping"
			((goterror++))
		fi

		# if this is kata-runtime, check how many pods virtcontainers thinks we have
		if [[ "$RUNTIME" == "containerd-shim-kata-v2" ]]; then
			num_vc_pods=$(sudo ls -1 ${VC_POD_DIR} | wc -l)

			if (( ${how_many_running} != ${num_vc_pods} )); then
				echo "Wrong number of pods in $VC_POD_DIR (${how_many_running} != ${num_vc_pods}) - stopping)"
				((goterror++))
			fi
		fi
	fi

	if (( goterror != 0 )); then
		show_system_ctr_state
		die "Got $goterror errors, quitting"
	fi
}

# reported system 'available' memory
get_system_avail() {
	echo $(free -b | head -2 | tail -1 | awk '{print $7}')
}

go() {
	echo "Running..."

	how_many=0

	while true; do {
		check_all_running

		local i
		for ((i=1; i<= ${MAX_CONTAINERS}; i++)); do
			containers+=($(random_name))
			sudo ctr run --runtime=${CTR_RUNTIME} -d ${nginx_image} ${containers[-1]} sh -c ${COMMAND}
			((how_many++))
		done

		if (( ${how_many} >= ${MAX_CONTAINERS} )); then
			echo "And we have hit the max ${how_many} containers"
			return
		fi

		how_much=$(get_system_avail)
		if (( ${how_much} < ${MEM_CUTOFF} )); then
			echo "And we are out of memory on container ${how_many} (${how_much} < ${MEM_CUTOFF})"
			return
		fi
	}
	done
}

kill_all_containers() {
	for container in $(sudo ctr containers list -q); do
		sudo ctr tasks kill "$container"
		# Give task a second to die if required
		waitForProcess 1 1 "! (sudo ctr tasks list -q | grep -q $container)"
		sudo ctr containers delete "$container"
	done
}

count_mounts() {
	echo $(mount | wc -l)
}

check_mounts() {
	final_mount_count=$(count_mounts)

	if [[ $final_mount_count < $initial_mount_count ]]; then
		echo "Final mount count does not match initial count (${final_mount_count} != ${initial_mount_count})"
	fi
}

init() {
	restart_containerd_service
	extract_kata_env
	kill_all_containers

	# remember how many mount points we had before we do anything
	# and then sanity check we end up with no new ones dangling at the end
	initial_mount_count=$(count_mounts)

	# Only check Kata items if we are using a Kata runtime
	if [[ "$RUNTIME" == "containerd-shim-kata-v2" ]]; then
		echo "Checking Kata runtime"
		check_kata_components=1
	else
		echo "Not a Kata runtime, not checking for Kata components"
		check_kata_components=0
	fi

	versions_file="${cidir}/../../versions.yaml"
	nginx_version=$("${GOPATH}/bin/yq" read "$versions_file" "docker_images.nginx.version")
	nginx_image="docker.io/library/nginx:$nginx_version"

	# Pull nginx image
	sudo ctr image pull ${nginx_image}
	if [ $? != 0 ]; then
		die "Unable to retry docker image ${nginx_image}"
	fi
}

spin() {
	local i
	for ((i=1; i<= ITERATIONS; i++)); do {
		echo "Start iteration $i of $ITERATIONS"
		#spin them up
		go
		#check we are in a sane state
		check_all_running
		#shut them all down
		kill_all_containers
		#Note there should be none running
		how_many=0
		#and check they all died
		check_all_running
		#and that we have no dangling mounts
		check_mounts
	}
	done

}

init
spin
