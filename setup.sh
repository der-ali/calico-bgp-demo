#!/bin/bash - 
#===============================================================================
#
#          FILE: setup.sh
# 
#         USAGE: ./setup.sh 
# 
#   DESCRIPTION: Establish a flat network between two Kubernetes clusters' resources by leveraging the capabilities of Calico, along with BGP reflectors.
# 
#  REQUIREMENTS: minikube, calico
#        AUTHOR: Ali Akil (), 
#       CREATED: 06/26/2023 11:41
#===============================================================================

# Treat unset variables as an error
set -o nounset

declare -A clusters
clusters[cluster1]="10.200.0.0/16 10.201.0.0/16"
clusters[cluster2]="10.210.0.0/16 10.211.0.0/16"


provision_minikube() {
for cluster in "${!clusters[@]}"; do
  # use bash parameter expansion as a workaround to get the first and second element
  # associative arrays can only hold scalar values and not arrays
  local pod_network_cidr=${clusters[$cluster]%% *}
  local service_cluster_ip_range=${clusters[$cluster]#* }
    minikube -p $cluster start  --extra-config=kubeadm.pod-network-cidr=${pod_network_cidr} --service-cluster-ip-range=${service_cluster_ip_range} --network=calico_cluster_peer_demo --container-runtime=containerd --nodes 4 --driver=kvm --memory 2048 --wait=all
  done
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
  sleep 10
  kubectl --cluster=$cluster wait --namespace=calico-system --for=condition=Ready pod -l k8s-app=calico-node --timeout=80s


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
  kubectl config use-context $cluster
  calicoctl apply -f ${cluster}_calicomanifests/bgp-configuration.yaml
}


apply_bgp_rr_config() {
  local cluster=$1
  local rr_nodes=$(get_rr_nodes ${cluster})
  for node in ${rr_nodes}; do
    kubectl config use-context $cluster 
    calicoctl apply -f ${cluster}_calicomanifests/bgp-configuration.yaml
    # Draining workloads from these nodes will ensure that disruption is minimal when BGP reconverges
    # Consider for production workloads
    #kubectl --cluster=$cluster drain --ignore-daemonsets $node
    # Make the target nodes RRs, by patching their node configurations with a route reflector cluster ID.
    calicoctl patch node $node -p '{"spec": {"bgp": {"routeReflectorClusterID": "244.0.0.1"}}}'
    # Apply a route-reflector=true Kubernetes label to the nodes that are now RRs
    kubectl --cluster=$cluster label node $node route-reflector=true
    # Apply a RR configuration manifest in both clusters instructing all nodes to establish a BGP peering with any node with that label
    calicoctl apply -f ${cluster}_calicomanifests/bgp-rr-configuration.yaml
    # Disable the automatic full mesh as it has been replaced by RRs
    #kubectl --cluster=$cluster uncordon $node
    # Prevent an IP pool from being used automatically by Calico IPAM
    # so that the IPs won’t actually be assigned to pods on the wrong cluster
    calicoctl apply -f ${cluster}_calicomanifests/disabled-othercluster-ippools.yaml
  done

}

get_nodes() {
  local cluster=$1
  kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# Get a list of the nodes which acts as Route Reflectors
get_rr_nodes() {
  local cluster=$1
  kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'| tail -2
}

get_rr_nodes_ips() {
  local cluster=$1
  kubectl --cluster=$cluster get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | tail -2

}

# exports the environment variables in the bgp-other-cluster.yaml template to be consumed by envsubst
define_template_vars() {
  # Second iteration needed for the environment variables inside bgp-other-cluster.yaml
  # During the first iteration over cluster2 the values for the env vars of cluster1 are not yet available.
  for cluster in "${!clusters[@]}"; do
    local rr_nodes_ip=($(get_rr_nodes_ips $cluster))
    local rr_nodes=($(get_rr_nodes $cluster))
    declare -A rr_nodes_map
    rr_nodes_map[${rr_nodes[0]}]=${rr_nodes_ip[0]}
    rr_nodes_map[${rr_nodes[1]}]=${rr_nodes_ip[1]}
    for rr_node in "${!rr_nodes_map[@]}"; do
      # Convert the node names to uppercase and subst '-' by '_' to match the env vars naming
      local tmp=${rr_node^^}
      local rr_node_var=${tmp//-/_}_IP
      # Output example: 
      # $rr_node_var=CLUSTER2_M03_IP
      # $CLUSTER2_M03_IP=192.168.39.203
      export $rr_node_var=${rr_nodes_map[$rr_node]}
    done
  done
}


template_config_files() {
  local cluster=$1
  envsubst < ${cluster}_calicomanifests/bgp-other-cluster.yaml
}

apply_templates() {
  local cluster=$1
  local config=$(template_config_files $cluster)
  kubectl config use-context $cluster
  calicoctl apply -f - <<< ${config}
}

# Define_template_vars function requires running clusters to parse the ip addresses
provision_minikube 

# Second iteration needed for the environment variables inside bgp-other-cluster.yaml
# During the first iteration over cluster2 the values for the env vars of cluster1 are not yet available.
define_template_vars

for cluster in "${!clusters[@]}"; do
  check_nodes_health $cluster
  setup_cni $cluster
  install_calicoctl $cluster
  check_bgp_status $cluster
  apply_bgp_rr_config $cluster
  apply_templates $cluster
  check_bgp_status $cluster
done
