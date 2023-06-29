# Calico BGP Demo 

This demo uses minikube to create 2 Kubernetes clusters (4 nodes) each and configures calico with route reflectors to establish a flat network between the two clusters.

<img src="/home/ali/Github/public/calico-bgp-demo/assets/FinalMinikubeBGPLab.drawio.png" alt="cluster" style="zoom: 67%;" />

Usage:
```
# Provision the clusters
./setup.sh
```

End-to-End Validation

```
# Create a server pod on cluster 1
kubectl --context cluster1 -n default run server -i --tty --image=giantswarm/tiny-tools --restart=Never  --rm -- sh
# Get the ip address of the pod
/ # hostname -i| awk '{print $1}'
# Start an nc server
/ # nc -l 10.210.60.1 1111

# On another terminal tab
# Create a clinet pod on cluster 2 
kubectl --context cluster2 -n default run client -i --tty --image=giantswarm/tiny-tools --restart=Never  --rm -- sh
# Start connect to the nc server
nc 10.210.60.1 1111
```



Please check the [Blog post](https://www.tigera.io/blog/experiment-with-calico-bgp-in-the-comfort-of-your-own-laptop/) for more details.