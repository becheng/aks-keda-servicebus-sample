# AKS KEDA Service Bus sample

Run a Python producer and consumer on Azure Kubernetes Service (AKS). KEDA scales the consumer on the Azure Service Bus queue backlog.

The sample uses Canada Central, Azure CNI Overlay with Cilium, and Microsoft Entra workload identity. Both applications and the KEDA scaler use workload identity on Azure. Service Bus connection-string authentication can remain disabled.

## Get started

1. Read the [Service Bus tutorial](tutorials/keda/service-bus/README.md).
2. Review the resource names in [shared settings](tutorials/keda/00-variables.sh).
3. Follow the tutorial prerequisites.
4. Run the numbered scripts from `tutorials/keda/service-bus/scripts`.

### Run the scripts on Windows

The verified Windows setup uses PowerShell to invoke Git for Windows Bash. From the repository root:

```powershell
$GitBash = 'C:\Program Files\Git\bin\bash.exe' # Adjust if Git is installed elsewhere.
Push-Location .\tutorials\keda\service-bus\scripts
try {
    & $GitBash ./04-build-docker-images.sh
    if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}
```

In this setup, `docker context show` returned `desktop-linux`, and `docker info --format '{{.ServerVersion}}|{{.OSType}}'` confirmed the Docker Desktop Linux engine (`29.9.3|linux`). Windows Terminal can host WSL instead; WSL needs Docker Desktop integration enabled for that distribution. Git Bash does not require WSL integration.

Provisioning creates billable Azure resources. Registry and Service Bus namespace names must be globally unique. The included values match the original sample deployment. Change them before creating a separate deployment.

The sample targets 1,000 Service Bus messages per second and sends 80 messages by default, preserving the short scale-out demonstration. It scales the consumer from zero to at most four replicas, drains the queue, and returns to zero. The tutorial includes offline provisioning, authentication, and producer-rate checks.

Only the Service Bus sample and its required shared settings are included. The source folder layout is retained so relative script paths continue to work.

## Run the scaling demonstration

Use this prompt to run the existing demonstration:

> Run the existing Service Bus scaling demonstration. Verify the selected Azure subscription and AKS context. Confirm the `work-items` queue is empty and the `sb-consumer` deployment has zero replicas. From `tutorials\keda\service-bus\scripts`, run `07-run-producer.sh` immediately followed by `08-watch-scaling.sh`. Use Git Bash with Windows tools and handle line endings correctly. Do not provision resources, rebuild images, or run cleanup. Report the observed scaling and queue results.

## Attribution

Adapted from the [Service Bus KEDA tutorial in localstack-samples/aks-samples](https://github.com/localstack-samples/aks-samples/tree/main/tutorials/keda/service-bus).

The original copyright notice and MIT license are preserved in [LICENSE](LICENSE).
