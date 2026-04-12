[CmdletBinding()]
param (
    [string]$Proxy = "",
    [string]$ContainerdIp = $(if ($env:USERNAME -eq 'Berkan') { "10.8.159.3" } else { "10.8.159.33" }),
    [string]$GvisorIp = $(if ($env:USERNAME -eq 'Berkan') { "10.8.159.2" } else { "10.8.159.34" }),
    [string[]]$Layers = @("baseline", "layer_1", "layer_2", "layer_3"),
    [string[]]$Environments = @("containerd", "gvisor", "gvisor-kvm"),
    [int]$Duration = 120,
    [int]$Iterations = 10,
    [int]$ControlPlaneWaitSeconds = 30,
    [switch]$SkipSetup,
    [switch]$Benchmarks,
    [switch]$Audits,
    [string]$OutputDirectory = ".\Results"
)

# Safely build proxy arguments
$Script:proxyArg = ""
$Script:setupProxyEnv = ""
if (-not [string]::IsNullOrWhiteSpace($Proxy)) {
    $Script:proxyArg = "-p $Proxy"
    $Script:setupProxyEnv = "HTTPS_PROXY=$Proxy HTTP_PROXY=$Proxy "
}

function Write-Log {
    param([string]$Message)
    Write-Host "`n[*] $Message" -ForegroundColor Cyan
}

# Build mode flags: default to both if neither switch is provided
$runBoth = (-not $Benchmarks) -and (-not $Audits)
$Script:modeFlags = @()
if ($Benchmarks -or $runBoth) { $Script:modeFlags += "-b" }
if ($Audits     -or $runBoth) { $Script:modeFlags += "-a" }
$Script:modeFlagsArg = $Script:modeFlags -join " "
# For gVisor-KVM: audit is skipped (results are identical to gVisor)
$Script:modeFlagsArgNoAudit = ($Script:modeFlags | Where-Object { $_ -ne "-a" }) -join " "
Write-Log "Mode flags: $Script:modeFlagsArg (KVM: $Script:modeFlagsArgNoAudit)"

function Invoke-SshCommand {
    param (
        [Parameter(Mandatory=$true)][string]$Node,
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$ErrorMessage = "SSH command failed"
    )
    ssh $Node $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage on $Node (Exit Code: $LASTEXITCODE)"
    }
}

function Measure-Environment {
    param (
        [string]$TargetName,
        [string]$TargetIp,
        [string]$AuditorName,
        [switch]$Kvm
    )

    Write-Log "Scenario: Benchmarking $TargetName (Target: $TargetIp, Auditor: $AuditorName)"
    
    foreach ($layer in $Layers) {
        Write-Log "Layer: $layer"
        
        if ($SkipSetup) {
            Write-Log "Skipping setup for $layer as per user request."
        }
        else {
            Write-Log "Step 1: Setting up $layer on $TargetName node..."
            # Using absolute /root path and proper bash syntax, running setup_layer.sh wrapper which handles Cleanup + Layer setup
            $setupCmd = "cd ~/; $Script:setupProxyEnv ./setup_layer.sh -l $layer $Script:proxyArg"
            if ($Kvm) {
                $setupCmd += " -k"
            }
            Invoke-SshCommand -Node $TargetName -Command $setupCmd -ErrorMessage "Setup failed for $layer on $TargetName"
        }

        Write-Log "Step 2: Executing benchmark from $AuditorName node..."
        $runtimeName = if ($Kvm) { "$TargetName-kvm" } else { $TargetName }
        $effectiveModeFlags = if ($Kvm) { $Script:modeFlagsArgNoAudit } else { $Script:modeFlagsArg }
        $benchCmd = "cd ~/benchmark; ./main.sh -t $TargetIp -l $layer -r $runtimeName -d $Duration $Script:proxyArg $effectiveModeFlags"
        Invoke-SshCommand -Node $AuditorName -Command $benchCmd -ErrorMessage "Benchmark failed for $layer"
        
        Write-Log "Completed $layer for $TargetName."
    }
}

# -------------------------------------------------------------------------
# Main Execution Block
# -------------------------------------------------------------------------
try {
    # Ensure base output directory exists
    if (-not (Test-Path $OutputDirectory)) {
        New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    }

    # Run an initial cleanup on both nodes before the first iteration to ensure
    # no leftover layer state from a previous session taints the first benchmarks.
    Write-Log "Running initial cleanup on all nodes before first iteration..."
    ssh gvisor "cd ~ && ./cleanup.sh"
    ssh containerd "cd ~ && ./cleanup.sh"

    for ($i = 1; $i -le $Iterations; $i++) {
        Write-Log "Starting Full Benchmark Iteration $i of $Iterations"
        
        # Reset remote directories (we ignore errors here using 2>/dev/null in bash, so no wrapper needed)
        ssh gvisor "rm -rf /root/results 2>/dev/null; mkdir -p /root/results"
        ssh containerd "rm -rf /root/results 2>/dev/null; mkdir -p /root/results"

        foreach ($envName in $Environments) {
            if ($envName -eq "gvisor") {
                # Scenario: Benchmark gVisor (Auditor: containerd)
                Measure-Environment -TargetName "gvisor" -TargetIp $GvisorIp -AuditorName "containerd"
            } elseif ($envName -eq "containerd") {
                # Scenario: Benchmark containerd (Auditor: gVisor)
                Measure-Environment -TargetName "containerd" -TargetIp $ContainerdIp -AuditorName "gvisor"
            } elseif ($envName -eq "gvisor-kvm") {
                # Scenario: Benchmark gVisor-KVM (Auditor: containerd)
                Measure-Environment -TargetName "gvisor" -TargetIp $GvisorKvmIp -AuditorName "containerd" -kvm
            } else {
                Write-Warning "Unknown environment: $envName"
            }
        }

        Write-Log "Iteration $i complete. Collecting results..."
        
        # Setup local run directories
        $runDir = Join-Path $OutputDirectory "run_$i"
        if (-not (Test-Path $runDir)) {
            New-Item -ItemType Directory -Force -Path $runDir | Out-Null
        }
        # Collect data via SCP
        scp -r "gvisor:/root/results/*" "$runDir/"
        scp -r "containerd:/root/results/*" "$runDir/"
    }

    Write-Log "All $Iterations iterations completed and data collected to $OutputDirectory."
    Write-Log "All benchmarking scenarios completed successfully."

    Compress-Archive -Path "$OutputDirectory\*" -DestinationPath "$OutputDirectory\benchmark_results.zip" -Force
}
catch {
    Write-Error "Benchmark suite halted due to an error:`n$_"
    exit 1
}