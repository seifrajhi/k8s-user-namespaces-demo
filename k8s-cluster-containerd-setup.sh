#!/bin/bash

# Exit immediately if a command exits with a non-zero status, Treat unset variables as an error and exit immediately, The return value of a pipeline is the status of the last command to exit with a non-zero status
set -euo pipefail

# Function to print colorful messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}\033[0m"
}

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'

# Check if figlet and toilet are installed, if not, install them
if ! command -v figlet &> /dev/null || ! command -v toilet &> /dev/null; then
    print_message $YELLOW "Figlet or Toilet not found, installing..."
    sudo apt-get update && sudo apt-get install -y figlet toilet
fi

# Print the title using figlet
figlet -f smblock "Script to setup forensic container checkpointing with CRIU in Kubernetes 1.30 and containerd runtime"

# Prompt the user for confirmation
echo "Do you wish to continue?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) 
            print_message $GREEN "Proceeding with installation..."
            break
            ;;
        No ) 
            print_message $RED "Installation aborted."
            exit
            ;;
    esac
done

# Start of the script
print_message $BLUE "Starting the script..."

# Disable swap
print_message $YELLOW "Disabling swap..."
swapoff -a
sed -i '/swap/d' /etc/fstab
sleep 1

# Load necessary kernel modules
print_message $YELLOW "Loading kernel modules..."
cat >>/etc/modules-load.d/containerd.conf<<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
sleep 1

# Configure sysctl for Kubernetes
print_message $YELLOW "Configuring sysctl for Kubernetes..."
cat >>/etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sleep 1

# Disable UFW
print_message $YELLOW "Disabling UFW..."
ufw disable
sleep 1

# Remove unnecessary packages
print_message $YELLOW "Removing unnecessary packages..."
sudo apt-get remove containernetworking-plugins -y && sudo apt-get remove conmon -y
sleep 1

# Create keyrings directory
print_message $YELLOW "Creating keyrings directory..."
mkdir -p /etc/apt/keyrings/
sleep 1

# Install containerd

apt-get update

# Download and install containerd
wget https://github.com/containerd/containerd/releases/download/v2.0.0/containerd-2.0.0-linux-amd64.tar.gz
tar -C /usr/local -xzvf containerd-2.0.0-linux-amd64.tar.gz

# Create systemd service file for containerd
mkdir -p /usr/local/lib/systemd/system/
cat <<EOF > /usr/local/lib/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target dbus.service

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5

# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity

# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start containerd
systemctl daemon-reload
systemctl enable --now containerd

# Download and install runc
wget https://github.com/opencontainers/runc/releases/download/v1.2.1/runc.amd64
install -m 755 runc.amd64 /usr/local/sbin/runc

# Download and install CNI plugins
wget https://github.com/containernetworking/plugins/releases/download/v1.6.0/cni-plugins-linux-amd64-v1.6.0.tgz
mkdir -p /opt/cni/bin
tar -C /opt/cni/bin -xzvf cni-plugins-linux-amd64-v1.6.0.tgz

systemctl restart containerd
# Verify containerd installation
containerd -v

# Add Kubernetes repository and install Kubernetes components
print_message $YELLOW "Adding Kubernetes repository and installing components..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-get update
sudo apt-get install kubelet kubeadm kubectl -y
sudo apt-mark hold kubelet kubeadm kubectl
sleep 1

# Output versions of Kubernetes components
print_message $BLUE "Kubernetes components versions:"
kubeadm version
kubelet --version
kubectl version --client
sleep 1

# Enable and start kubelet
print_message $YELLOW "Enabling and starting kubelet..."
sudo systemctl enable --now kubelet
sleep 1

# Initialize Kubernetes cluster
print_message $YELLOW "Initializing Kubernetes cluster..."
kubeadm init --pod-network-cidr=192.168.0.0/16 --cri-socket unix:///run/containerd/containerd.sock --ignore-preflight-errors=NumCPU
sleep 1

# Configure kubectl for the current user
print_message $YELLOW "Configuring kubectl for the current user..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl cluster-info dump
sleep 1

# Remove taints on control-plane nodes
print_message $YELLOW "Removing taints on control-plane nodes..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl get nodes -o wide
sleep 1

# Exit the script
exit 0
