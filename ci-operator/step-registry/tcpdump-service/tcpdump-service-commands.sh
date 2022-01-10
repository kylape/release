#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Injecting manifest to deploy tcpdump service MachineConfig with script and systemd units"

echo

# Echo a script to be run as our systemd unit to a file so we can base64 encode it.
sysd_script=$(cat << EOF
#!/bin/sh

set -e

# Build up a tcpdump filter for all quay.io and registry.ci IPs.
# quay.io IPs change often so by doing the lookup before we launch
# we increase our chances of dumping the packets we're after.
# Use grep to filter out CNAME responses and get only the A records.
registry_ip_lines=\$(dig +short quay.io registry.ci.openshift.org | grep -v "\.$")

tcpdump_filter=""
for i in \$registry_ip_lines
do
    if [ -z "\$tcpdump_filter" ]
    then
        tcpdump_filter+="(host \$i"
    else
        tcpdump_filter+=" or host \$i"
    fi
done
# Close our tcpdump filter brace:
tcpdump_filter+=")"

echo "tcpdump filter: \$tcpdump_filter"
echo
echo "Running tcpdump:"
echo

/usr/sbin/tcpdump -nn -U -i any -s 256 -w '/var/log/tcpdump/tcpdump.pcap' \$tcpdump_filter
EOF
)

# Base64 encode the script for use in the MachineConfig.
b64_script=$(echo "$sysd_script" | base64 -w 0)

# Create the MachineConfig manifest with embedded b64 encoded systemd script, and the two
# systemd units to (a) install tcpdump, and (b) run the script.
cat > "${SHARED_DIR}/manifest_tcpdump_service_machineconfig.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: tcpdump-service
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          # Script contents are a simple base64 -w 0 encoding of the tcpdump-service.sh script defined above.
          source: data:text/plain;charset=utf-8;base64,$b64_script
        filesystem: root
        mode: 0755
        path: /var/usrlocal/bin/tcpdump-quay.sh
    systemd:
      units:
      - contents: |
          [Unit]
          Description=install tcpdump
          After=network-online.target
          Wants=network-online.target
          Before=machine-config-daemon-firstboot.service
          Before=kubelet.service

          [Service]
          Type=oneshot
          ExecStart=rpm-ostree usroverlay
          ExecStart=rpm -ihv http://mirror.centos.org/centos/8/AppStream/x86_64/os/Packages/tcpdump-4.9.3-2.el8.x86_64.rpm
          RemainAfterExit=yes

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: install-tcpdump.service
      - contents: |
          [Unit]
          After=network.target
          After=install-tcpdump.service

          [Service]
          Restart=always
          RestartSec=30
          ExecStart=/var/usrlocal/bin/tcpdump-quay.sh
          ExecStop=/usr/bin/kill -s QUIT \$MAINPID
          LogsDirectory=tcpdump

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: tcpdump.service
EOF

echo "manifest_tcpdump_service_machineconfig.yaml"
echo "---------------------------------------------"
cat ${SHARED_DIR}/manifest_tcpdump_service_machineconfig.yaml