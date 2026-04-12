function Log-Message([string]$msg) {
    Write-Host "`n[*] $msg" -ForegroundColor Cyan
}

Log-Message "Starting to upload layers and benchmark scripts to gVisor and containerd nodes."
Log-Message "****************************************************************"
Log-Message "Dont forget to update PROXY Variable in run_all_benchmarks.ps1"
Log-Message "****************************************************************"

scp -r .\scripts\* gvisor:/root
scp -r .\scripts\* containerd:/root

ssh -q gvisor "chmod +x /root/chmod_all.sh; /root/chmod_all.sh"
ssh -q containerd "chmod +x /root/chmod_all.sh; /root/chmod_all.sh"