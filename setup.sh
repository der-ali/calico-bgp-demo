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
cluster="cluster1"

provision_minikube() {
minikube -p $cluster start  --extra-config=kubeadm.pod-network-cidr=10.200.0.0/16 --service-cluster-ip-range=10.201.0.0/16 --network=calico_cluster_peer_demo --container-runtime=containerd --nodes 4 --driver=kvm --memory 2048 --wait=all
}


# Function to check if a Kubernetes node is healthy
check_node_health() {
    local node=$1
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
  for node in ${NODES}; do
      check_node_health ${node}
  done
}

setup_cni() {
  kubectl --cluster=$cluster create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml 2> /dev/null
  kubectl --cluster=$cluster create -f ${cluster}_calicomanifests/custom-resources.yaml 2> /dev/null
  kubectl --cluster=$cluster delete ds -n=kube-system kindnet
  sleep 5
  kubectl --cluster=$cluster wait --namespace=calico-system --for=condition=Ready pod -l k8s-app=calico-node


}

install_calicoctl() {
  for node in ${NODES}; do
    minikube ssh -p $cluster -n $node "curl -o calicoctl -O -L http://github.com/projectcalico/calicoctl/releases/download/v3.21.4/calicoctl && sudo mv calicoctl /usr/bin/calicoctl && chmod +x /usr/bin/calicoctl"
  done
}

check_bgp_status() {
  for node in ${NODES}; do
    minikube ssh -p $cluster -n $node "sudo calicoctl node status"
  done

}

apply_bgp_config() {
  kubectl config use-context $cluster && calicoctl apply -f ${cluster}_calicomanifests/bgp-configuration.yaml
}


apply_bgp_rr_config() {
  for node in ${RR_NODES}; do
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

provision_minikube
NODES=$(kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
RR_NODES=$(kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'| tail -2)
check_nodes_health
setup_cni
install_calicoctl
apply_bgp_rr_config

