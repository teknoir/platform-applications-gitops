# Deadend Bastion Helm Chart

This chart deploys Deadend Bastion resources to a Kubernetes cluster.

> The implementation of the Helm chart is the bare minimum.
> The Helm Chart is not meant to be infinitely configurable, but to provide a quick way to deploy Deadend Bastion to a Kubernetes cluster.

## Usage in Teknoir platform
Use the HelmChart to deploy the Deadend Bastion resources to a Teknoir Cluster.

```yaml
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: deadend
  namespace: demonstrations
spec:
  repo: https://teknoir.github.io/deadend-helm
  chart: deadend
  targetNamespace: demonstrations
  valuesContent: |-
    # Example for minimal configuration
    
```

## Adding the repository

```bash
helm repo add teknoir-deadend https://teknoir.github.io/deadend-helm/
```

## Installing the chart

```bash
helm install deadend teknoir-deadend/deadend -f values.yaml
```
