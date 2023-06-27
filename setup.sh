#!/bin/bash - 
#===============================================================================
#
#          FILE: setup-cluster1.sh
# 
#         USAGE: ./setup-cluster1.sh 
# 
#   DESCRIPTION: 
# 
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: YOUR NAME (), 
#  ORGANIZATION: 
#       CREATED: 06/26/2023 11:41
#      REVISION:  ---
#===============================================================================

set -o nounset                              # Treat unset variables as an error
declare -A clusters
clusters[cluster1]="10.200.0.0/16 10.201.0.0/16"
clusters[cluster2]="10.210.0.0/16 10.211.0.0/16"


provision_minikube() {
  local cluster=$1
  local pod_network_cidr=$2
  local service_cluster_ip_range=$3
    minikube -p $cluster start  --extra-config=kubeadm.pod-network-cidr=${pod_network_cidr} --service-cluster-ip-range=${service_cluster_ip_range} --network=calico_cluster_peer_demo --container-runtime=containerd --nodes 4 --driver=kvm --memory 2048 --wait=all
}


# Function to check if a Kubernetes node is healthy
check_node_health() {
  local node=$1
  local cluster=$2
  local health_status=$(kubectl --cluster=$cluster get node $node -o jsonpath='{range @.status.conditions[-1:]}{.status}{end}')

  if [[ "$health_status" != "True" ]]; then
      echo "Node $node is not healthy!"
      exit 1
  else
      echo "Node $node is healthy."
  fi
}

check_nodes_health() {
  # Loop through each node and check its health
  local cluster=$1
  local nodes=$(get_nodes ${cluster})

  for node in $nodes; do
    check_node_health ${node} ${cluster}
  done
}

setup_cni() {
  local cluster=$1
  kubectl --cluster=$cluster create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml 2> /dev/null
  kubectl --cluster=$cluster create -f ${cluster}_calicomanifests/custom-resources.yaml 2> /dev/null
  kubectl --cluster=$cluster delete ds -n=kube-system kindnet
  sleep 5
  kubectl --cluster=$cluster wait --namespace=calico-system --for=condition=Ready pod -l k8s-app=calico-node


}

install_calicoctl() {
  local cluster=$1
  local nodes=$(get_nodes ${cluster})
  for node in ${nodes}; do
    minikube ssh -p $cluster -n $node "curl -o calicoctl -O -L http://github.com/projectcalico/calicoctl/releases/download/v3.21.4/calicoctl && sudo mv calicoctl /usr/bin/calicoctl && chmod +x /usr/bin/calicoctl"
  done
}

check_bgp_status() {
  local cluster=$1
  local nodes=$(get_nodes ${cluster})
  for node in ${nodes}; do
    minikube ssh -p $cluster -n $node "sudo calicoctl node status"
  done

}

apply_bgp_config() {
  local cluster=$1
  kubectl config use-context $cluster && calicoctl apply -f ${cluster}_calicomanifests/bgp-configuration.yaml
}


apply_bgp_rr_config() {
  local cluster=$1
  local rr_nodes=$(get_rr_nodes ${cluster})
  for node in ${rr_nodes}; do
    kubectl config use-context $cluster 
    calicoctl apply -f ${cluster}_calicomanifests/bgp-configuration.yaml
    #kubectl --cluster=$cluster drain --ignore-daemonsets $node
    calicoctl patch node $node -p '{"spec": {"bgp": {"routeReflectorClusterID": "244.0.0.1"}}}'
    kubectl --cluster=$cluster label node $node route-reflector=true
    calicoctl apply -f ${cluster}_calicomanifests/bgp-rr-configuration.yaml
    calicoctl patch bgpconfiguration default -p '{"spec": {"nodeToNodeMeshEnabled": false}}'
    #kubectl --cluster=$cluster uncordon $node
  done

}

get_nodes() {
  local cluster=$1
  kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

get_rr_nodes() {
  local cluster=$1
  kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'| tail -2
}

for cluster in "${!clusters[@]}"; do
  pod_network_cidr=${clusters[$cluster]%% *}
  service_cluster_ip_range=${clusters[$cluster]#* }
  provision_minikube $cluster ${pod_network_cidr} ${service_cluster_ip_range}
  check_nodes_health $cluster
  setup_cni $cluster
  install_calicoctl $cluster
  check_bgp_status $cluster
  apply_bgp_rr_config
done

