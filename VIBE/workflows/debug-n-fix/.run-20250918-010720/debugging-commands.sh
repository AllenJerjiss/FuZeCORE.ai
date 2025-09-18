=== DEBUGGING PLAN GENERATOR ===

=== CONFIRMING INPUT FROM rca-initial-analysis.txt ===
=== ROOT CAUSE ANALYSIS - INITIAL FINDINGS ===

CRITICAL QUESTIONS FOR ROOT CAUSE ANALYSIS:

1. DIRECTORY MIGRATION TIMELINE:
   Q: When did /FuZe/models/ollama stop being used?
   Q: What triggered the move to /FuZe/ollama?
   Q: Are there any lingering references to the old path?
   Q: Why is /FuZe/baked/ollama empty but exists?

2. SERVICE CONFIGURATION INCONSISTENCIES:
   Q: Why are all ollama services inactive?
   Q: What was the last known working service configuration?
   Q: Are GPU assignments (CUDA_VISIBLE_DEVICES) correctly mapped?
   Q: Do service files point to correct model directories?

3. MODEL NAMING CONVENTION EVOLUTION:
   Q: Why do we have both gpu0 and 3090ti patterns?
   Q: What was the exact sequence of renaming operations?
   Q: Are there orphaned models with old naming?
   Q: Do cleanup scripts handle mixed naming patterns?

4. CLEANUP SCRIPT MODIFICATION RISKS:
   Q: What would happen if service-cleanup.sh runs with wrong MODELDIR?
   Q: Could store-cleanup.sh migrate models to non-existent directories?
   Q: Will cleanup-variants.sh regex miss existing model patterns?
   Q: What safeguards exist against data loss?

5. SYSTEM STATE VALIDATION:
   Q: Are there active ollama processes not managed by systemd?
   Q: What disk space issues might exist with 1TB+ models?
   Q: Are there permission issues preventing service startup?
   Q: Do network ports conflict between service instances?

IDENTIFIED FAILURES FROM FORENSIC ANALYSIS:
   FAILURE: ✗ /FuZe/models (missing)
   FAILURE: ✗ /FuZe/models/ollama (missing)
   FAILURE: ✗ /FuZe/ollama/models (missing)
   FAILURE: ✗ service-cleanup.sh -> MODELDIR path (MISSING!)
   FAILURE: ✗ store-cleanup.sh -> CANON/ALT_DEFAULT paths (MISSING!)
   FAILURE: ✗ cleanup-variants.sh -> MATCH_RE regex pattern (MISSING!)
   FAILURE: ✗ nuke-all.sh -> NEW FILE - nuclear cleanup wrapper (MISSING!)

UNRECOGNIZED PATTERNS DETECTED:
   UNKNOWN: ? unknown pattern: LLM-FuZe-gpt-oss-20b-gpu0-ng80
   UNKNOWN: ? unknown pattern: LLM-FuZe-LLM-FuZe-gpt-oss-20b-gpu0-ng80-latest-gpu0-ng80

RECOMMENDED IMMEDIATE ACTIONS:
1. Validate all service configurations before enabling
2. Test cleanup scripts in dry-run mode first
3. Backup critical model data before any cleanup
4. Verify GPU assignments match actual hardware
5. Create rollback plan for all modifications

RISK ASSESSMENT:
HIGH RISK: Data loss from incorrect cleanup operations
MEDIUM RISK: Service startup failures from path mismatches
LOW RISK: Performance impact from inactive services


=== END OF INPUT CONFIRMATION ===

Debugging commands written to debugging-commands.sh (executable)
#!/bin/bash
# Auto-generated debugging commands from RCA analysis

echo "=== DEBUGGING COMMANDS TO GATHER EVIDENCE ==="

echo "# 1. DIRECTORY MIGRATION TIMELINE EVIDENCE:"
echo "# Check filesystem timestamps and modification dates"
stat /FuZe/ollama
stat /FuZe/baked/ollama
ls -la /FuZe/ | grep ollama
find /FuZe -name "*ollama*" -type d -exec stat {} \;
echo "# Check for old path references in configs"
grep -r "/FuZe/models/ollama" /etc/systemd/system/ 2>/dev/null || echo "No old path refs in systemd"
grep -r "/FuZe/models/ollama" /home/fuze/ 2>/dev/null | head -10 || echo "No old path refs in home"
echo
echo "# 2. SERVICE CONFIGURATION INVESTIGATION:"
echo "# Check service files and their current state"
systemctl cat ollama.service
systemctl cat ollama-test-a.service
systemctl cat ollama-test-b.service
systemctl cat ollama-test-multi.service
systemctl cat ollama-persist.service
echo "# Check service logs for errors"
journalctl -u ollama.service --since "1 hour ago" --no-pager | tail -20
journalctl -u ollama-test-a.service --since "1 hour ago" --no-pager | tail -20
echo "# Check what's preventing service startup"
systemctl status ollama.service
systemctl status ollama-test-a.service
echo
# 3. GPU AND HARDWARE VALIDATION:
# Verify actual GPU hardware vs service configs
nvidia-smi --list-gpus
nvidia-smi --query-gpu=index,name,uuid --format=csv,noheader
# Check current CUDA_VISIBLE_DEVICES settings
env | grep CUDA
# Verify GPU accessibility
nvidia-smi

# 4. MODEL VARIANT DETAILED ANALYSIS:
# List all model manifests with timestamps
ls -la /FuZe/ollama/manifests/
# Check model sizes and disk usage
du -sh /FuZe/ollama/blobs/*
# Analyze model naming patterns in detail
find /FuZe/ollama/manifests -name "*LLM-FuZe*" -exec basename {} \; | sort
find /FuZe/ollama/manifests -name "*gpu0*" -exec basename {} \;
find /FuZe/ollama/manifests -name "*3090ti*" -exec basename {} \;

# 5. PROCESS AND NETWORK ANALYSIS:
# Check for running ollama processes
ps aux | grep ollama
pgrep -f ollama
# Check network port usage
netstat -tlnp | grep :11434
ss -tlnp | grep ollama
lsof -i :11434 2>/dev/null || echo "Port 11434 not in use"

# 6. DISK SPACE AND PERMISSIONS ANALYSIS:
# Check disk space issues
df -h /FuZe
du -sh /FuZe/ollama
# Check permissions on critical paths
ls -ld /FuZe/ollama
ls -ld /FuZe/ollama/manifests
ls -ld /FuZe/ollama/blobs
# Check who owns the ollama directories
stat -c '%U:%G %n' /FuZe/ollama
stat -c '%U:%G %n' /FuZe/ollama/manifests

# 7. CONFIGURATION FILE ANALYSIS:
# Look for ollama config files
find /etc -name "*ollama*" 2>/dev/null
find /home/fuze -name "*ollama*" 2>/dev/null | head -10
# Check environment files
ls -la /home/fuze/GitHub/FuZeCORE.ai/factory/LLM/refinery/stack/env/
find /home/fuze/GitHub/FuZeCORE.ai -name "*.env*" | head -10

echo "=== END OF DEBUGGING COMMANDS ==="
echo "# Run this script to execute all debugging commands"
echo "# Each command provides evidence to answer the RCA questions"
