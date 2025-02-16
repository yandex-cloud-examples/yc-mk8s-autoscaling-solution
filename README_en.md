# Demo scenario for autoscaling in Yandex Cloud Managed Service for Kubernetes

This scenario demonstrates how autoscaling works based on Horizontal Pod Autoscaler and Cluster Autoscaler. 

Horizontal Pod Autoscaler automatically scales the number of pods in a deployment, replica set or stateful set based on monitored CPU or RAM utilization by the Metric Server (or based on custom metrics, i.e., some other metrics from the app).

![](https://d33wubrfki0l68.cloudfront.net/4fe1ef7265a93f5f564bd3fbb0269ebd10b73b4e/1775d/images/docs/horizontal-pod-autoscaler.svg)

Cluster Autoscaler is a tool that automatically adjusts the number of worker nodes in a Kubernetes cluster when one of the following conditions is met:

* There are pods that cannot be run due to insufficient resources in the cluster.
* There are worker nodes in the cluster that have been underutilized for a long time, and their pods can be relocated to other existing nodes.

The demo bench consists of a Yandex Virtual Private Cloud network with subnets in three availability zones (AZs), a regional Managed Service for Kubernetes cluster, and three node groups in different AZs with autoscaling enabled.

This demo is focused on two scenarios:
* Scaling based on the CPU usage of pods using the built-in Metric Server.
* Scaling based on Ingress RPS using the Prometheus adapter.

## Requirements

* Terraform v0.14 or higher
* YC CLI
* Helm 3
* Bash
* wget 
* watch

### Configuring Yandex Cloud

* Install the [YC CLI](https://cloud.yandex.com/docs/cli/quickstart).
* Configure the YC authorization for Terraform.

```
export YC_TOKEN=$(yc iam create-token)
export YC_CLOUD_ID=$(yc config get cloud-id)
export YC_FOLDER_ID=$(yc config get folder-id)
``` 

## Quick start

Create a Managed Kubernetes cluster:

```
terraform init
terraform apply
```

Let's add credentials to the `kubectl` configuration file. Specify the cluster name or ID:

```
yc managed-kubernetes cluster get-credentials demo --external
```

### Scaling based on CPU utilization

Create a deployment, `service(LoadBalanсer)`, and HPA for the test app:

```
kubectl apply -f k8s_autoscale-CPU.yaml
```

Let's start monitoring the Kubernetes cluster components of interest in a separate window:

```
watch kubectl get pod,svc,hpa,nodes -o wide
```

Simulate the workload by continuously sending requests with `wget` to the external IP address of the load balancer:

```bash
URL=$(kubectl get service nginx -o json| jq -r '.status.loadBalancer.ingress[0].ip')
while true; do wget -q -O- http://$URL; done     
# Where `$URL` stands for the external IP address of the service.
```

You should see the number of pods in `nginx` deployment grow first, and then, the number of nodes in Kubernetes Node Groups in different availability zones.

When you end the workload simulation loop, the system will automatically remove the deployment replicas that have no load.

After 7 to 10 minutes, the Kubernetes cluster will start removing the unutilized nodes.

Delete the created Kubernetes objects:

```
kubectl delete -f k8s_autoscale-CPU.yaml

```

### Scaling based on RPS utilization

To install additional components, use Helm.

Add Helm repos:

```
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

Install the Nginx Ingress Controller with metrics view enabled:

```
helm upgrade --install rps ingress-nginx/ingress-nginx --values values-ingr.yaml
```
The ingress controller reports a metric to Prometheus with the total number of requests rather than for a specific time interval. Meanwhile, HPA cannot handle functions for processing Prometheus metrics, so getting the metric requires a specific Prometheus recording rule.

To achieve this, add the rule to the Helm values for Prometheus:

```yaml
rules:
  groups:
    - name: Ingress
      rules:
        - record: nginx_ingress_controller_requests_per_second
          expr: rate(nginx_ingress_controller_requests[2m])
```

Install Prometheus: 

```
helm upgrade --install prometheus prometheus-community/prometheus --values values-prom.yaml
```

Install Prometheus adapter, as you will need it to access Prometheus metrics via `kube-api`. The file named `values-prom-ad.yaml` specifies the Prometheus address and port, as well as the rule for `nginx_ingress` metrics:

```
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter --values values-prom-ad.yaml
```

Create a deployment, service, ingress, and HPA for the second test app:

```
kubectl apply -f k8s_autoscale-RPS.yaml
```

Once complete, Prometheus will be providing a new metric named `nginx_ingress_controller_requests_per_second`.

Make sure the `nginx_ingress_controller_requests_per_second` metric is available via `kube-api`.

Prometheus will not start computing that metric until after traffic passes through the Ingress controller. This is why you need to run a few test requests by running the below command two or three times:

```bash
URL=$(kubectl get service rps-ingress-nginx-controller -o json| jq -r '.status.loadBalancer.ingress[0].ip')
curl -H "Host: nginx.example.com" http://$URL
# Where `$URL` stands for the external IP address of the `rps-ingress-nginx-controller` service.
```

Then, run this command:

```
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 |jq .| grep ingresses.networking.k8s.io/nginx_ingress_controller_requests_per_second
```

Within a couple minutes, you should have the following result: `"name": "ingresses.networking.k8s.io/nginx_ingress_controller_requests_per_second",`.

### Checking the result

Let's start monitoring the Kubernetes cluster components of interest in a separate window:

```
watch kubectl get pod,svc,hpa,nodes -o wide
```

Note that running `watch kubectl get pod,svc,hpa,nodes -o wide` will always return `TARGETS 0/0` for `nginx HPA`; this is a bug. For the correct value, see `kubectl describe hpa nginx`.

Simulate the workload by continuously sending requests with `curl` to the external IP address of the `rps-ingress-nginx-controller` service:

```bash
URL=$(kubectl get service rps-ingress-nginx-controller -o json| jq -r '.status.loadBalancer.ingress[0].ip')
while true; do curl -H "Host: nginx.example.com" http://$URL; done
# Where `$URL` stands for the external IP address of the `rps-ingress-nginx-controller` service.
```

A few minutes later, you should see the number of pods in `nginx` deployment grow first, and then, the number of nodes in Kubernetes Node Groups in different availability zones.

When you end the workload simulation loop, the system will automatically remove the deployment replicas that have no load.

After 7 to 10 minutes, the Kubernetes cluster will start removing the unutilized nodes.

### Delete the test bench.

```
terraform destroy
```
