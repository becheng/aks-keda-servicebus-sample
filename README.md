# AKS KEDA Service Bus sample

Run a Python producer and consumer on Azure Kubernetes Service (AKS). KEDA scales the consumer on the Azure Service Bus queue backlog.

The sample uses Canada Central, Azure CNI Overlay with Cilium, and Microsoft Entra workload identity. Both applications and the KEDA scaler use workload identity on Azure. Service Bus connection-string authentication can remain disabled.

## Get started

1. Read the [Service Bus tutorial](tutorials/keda/service-bus/README.md).
2. Review the resource names in [shared settings](tutorials/keda/00-variables.sh).
3. Follow the tutorial prerequisites.
4. Run the numbered scripts from `tutorials/keda/service-bus/scripts`.

Provisioning creates billable Azure resources. Registry and Service Bus namespace names must be globally unique. The included values match the original sample deployment. Change them before creating a separate deployment.

The sample sends 80 messages. It scales the consumer from zero to at most four replicas, drains the queue, and returns to zero. The tutorial includes offline provisioning and authentication checks.

Only the Service Bus sample and its required shared settings are included. The source folder layout is retained so relative script paths continue to work.

## Run against LocalStack

This repository targets Azure. Emulator compatibility remains in the application code. See the [upstream LocalStack setup guide](https://github.com/localstack-samples/aks-samples#run-against-localstack) for emulator instructions.

## Attribution

Adapted from the [Service Bus KEDA tutorial in localstack-samples/aks-samples](https://github.com/localstack-samples/aks-samples/tree/main/tutorials/keda/service-bus).

The original copyright notice and MIT license are preserved in [LICENSE](LICENSE).
