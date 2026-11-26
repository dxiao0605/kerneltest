#!/bin/bash
#================================================================
# check_key_usage.sh
# Check whether the RSA key (/root/.ssh/id_rsa) is still in use on this node.
#
# The script is strictly READ-ONLY: it only inspects fingerprints,
# authorized_keys, configs, cron entries and auth logs.
# It creates no directories and modifies nothing on the node.
#
# Report: saved to /home/jinny/temp/key_usage_<hostname>_<timestamp>.log
#         (directory must already exist; if missing, output is screen-only).
#
# Mode A - run locally on a node (as root, or as 'jinny' with sudo):
#   bash /home/jinny/temp/check_key_usage.sh
#
# Mode B - run remotely from MMSC1 for all LB nodes:
#   for n in <LB01P-IP> <LB02P-IP> <LB01S-IP>; do
#     echo "##### $n #####"
#     scp -q /home/jinny/temp/check_key_usage.sh jinny@$n:/home/jinny/temp/
#     ssh -t jinny@$n 'bash /home/jinny/temp/check_key_usage.sh'
#   done
#
# No direct root SSH? The script auto-elevates: run it as a normal user
# (e.g. jinny) and it re-executes itself via sudo (password prompt appears;
# requires 'ssh -t' so sudo can ask for the password).
#
# Custom key path:
#   KEY=/path/to/id_rsa bash check_key_usage.sh
#================================================================

#--- Auto-elevate: if not root, re-run itself via sudo -----------------
# Requires the script to exist as a FILE on the node (not piped via
# 'bash -s').
if [ "$(id -u)" -ne 0 ]; then
    if [ ! -f "$0" ] || [ "$0" = "bash" ]; then
        echo "[!] Not running as root, and script was piped via stdin,"
            echo "    so it cannot re-exec itself with sudo."
        echo "    Fix: upload it first (scp), then: ssh -t jinny@<node> 'bash /home/jinny/temp/check_key_usage.sh'"
        exit 1
    fi
    echo "[i] Not root -> elevating with sudo (password prompt may appear)..."
    exec sudo bash "$0" "$@"
fi

KEY="${KEY:-/root/.ssh/id_rsa}"
PUB="${KEY}.pub"
HOSTNAME_N=$(hostname)
REPORT_DIR="/home/jinny/temp"

# Report file: output is displayed AND saved to $REPORT_DIR
# (directory must already exist; if missing, output goes to screen only).
if [ -d "$REPORT_DIR" ]; then
    REPORT_FILE="$REPORT_DIR/key_usage_$(hostname)_$(date '+%Y%m%d_%H%M%S').log"
    exec > >(tee -a "$REPORT_FILE") 2>&1
    echo "[i] Report file: $REPORT_FILE"
else
    echo "[i] $REPORT_DIR does not exist - report will NOT be saved (screen output only)."
fi

echo "=========================================================="
echo "[$HOSTNAME_N] Key usage check : $KEY"
echo "Check time           : $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================================="

IN_USE=0            # 0 = no evidence of usage
REASONS=""

#----------------------------------------------------------
# 0. Key exists & fingerprint
#----------------------------------------------------------
if [ ! -f "$KEY" ]; then
    echo "[!] Private key not found: $KEY (skipping this node)"
    exit 0
fi
if [ ! -f "$PUB" ]; then
    # reconstruct .pub from the private key (without comment)
    ssh-keygen -y -f "$KEY" > "${PUB}.tmp" 2>/dev/null && mv "${PUB}.tmp" "$PUB"
fi

FP=$(ssh-keygen -lf "$PUB" 2>/dev/null | awk '{print $2}')
if [ -z "$FP" ]; then
    echo "[!] Failed to compute fingerprint from $PUB (corrupt key / not OpenSSH format?)"
    exit 0
fi

# base64 body of pub key -> for matching inside authorized_keys
KEYBODY=$(awk '{print $2}' "$PUB")
PERM=$(stat -c '%a %U:%G' "$KEY" 2>/dev/null)
MTIME=$(stat -c '%y' "$KEY" 2>/dev/null | cut -d. -f1)

echo "Fingerprint   : $FP"
echo "Pub body      : $(echo "$KEYBODY" | cut -c1-40)... ($(echo -n "$KEYBODY" | wc -c) chars)"
echo "Key mtime     : $MTIME | Perm: $PERM"
echo "(Compare fingerprints across nodes: identical = shared key)"

#----------------------------------------------------------
# 1. INBOUND - used by others/machines to log in to this node
#----------------------------------------------------------
echo
echo "--- 1. INBOUND (authorized_keys on this node) ---"
AK_FILES=$(find /root /home /etc -name authorized_keys -type f 2>/dev/null)
FOUND_IN=0
if [ -z "$AK_FILES" ]; then
    echo "    No authorized_keys file found."
else
    while read -r f; do
        if grep -Fq "$KEYBODY" "$f" 2>/dev/null; then
            OWNER=$(stat -c '%U' "$(dirname "$f")" 2>/dev/null)
            echo "    [REGISTERED] $f (owner: $OWNER)"
            FOUND_IN=1
            IN_USE=1
            REASONS="$REASONS\n    - inbound: registered in $f"
        fi
    done <<< "$AK_FILES"
    [ "$FOUND_IN" = 0 ] && echo "    This key's fingerprint is NOT present in any authorized_keys."
fi

#----------------------------------------------------------
# 2. OUTBOUND - used by this node to SSH to other servers
#----------------------------------------------------------
echo
echo "--- 2. OUTBOUND (id_rsa references in configs/cron/scripts) ---"
FOUND_OUT=0
OUT_DIRS="/root/.ssh /etc/ssh /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.hourly /var/spool/cron /etc/systemd/system /usr/local/bin /opt /usr/local/sbin"

for tgt in $(find $OUT_DIRS -maxdepth 4 -type f 2>/dev/null | grep -v "id_rsa$\|known_hosts$\|authorized_keys$"); do
    # look for id_rsa references OR the key body
    if grep -l -e "id_rsa" -e "$KEYBODY" "$tgt" >/dev/null 2>&1; then
        echo "    [REFERENCED] $tgt:"
        grep -n -e "id_rsa" -e "$KEYBODY" "$tgt" 2>/dev/null | head -5 | sed 's/^/        /'
        FOUND_OUT=1
        IN_USE=1
        REASONS="$REASONS\n    - outbound: referenced in $tgt"
    fi
done
[ "$FOUND_OUT" = 0 ] && echo "    No id_rsa references found in configs/cron/systemd/scripts."

# currently running SSH processes
ACTIVE=$(ps aux 2>/dev/null | grep -i "[s]sh " | grep -v "sshd:")
if [ -n "$ACTIVE" ]; then
    echo "    Active SSH processes right now:"
    echo "$ACTIVE" | sed 's/^/        /'
fi

#----------------------------------------------------------
# 3. LOGS - historical usage evidence (Accepted publickey)
#----------------------------------------------------------
echo
echo "--- 3. LOGS (evidence of logins with this key) ---"
LOGS=$(ls -1 /var/log/secure /var/log/secure-* /var/log/auth.log /var/log/auth.log.* 2>/dev/null | sort -u)
TOTAL=0
IP_LIST=""
LASTLINE=""
if [ -z "$LOGS" ]; then
    echo "    [!] Auth logs not found (/var/log/secure or /var/log/auth.log)."
else
    for lf in $LOGS; do
        case "$lf" in
            *.gz) C=$(zgrep -c "$FP" "$lf" 2>/dev/null) ;;
            *)    C=$(grep -c  "$FP" "$lf" 2>/dev/null) ;;
        esac
        [ -z "$C" ] && C=0
        if [ "$C" -gt 0 ]; then
            TOTAL=$((TOTAL + C))
            case "$lf" in
                *.gz) MATCH=$(zgrep -h "$FP" "$lf" 2>/dev/null) ;;
                *)    MATCH=$(grep -h  "$FP" "$lf" 2>/dev/null) ;;
            esac
            LASTLINE=$(echo "$MATCH" | tail -1)
            # extract source IPs from "Accepted publickey for ... from <IP>" lines
            IP=$(echo "$MATCH" | grep "Accepted" | \
                 awk '{for(i=1;i<=NF;i++) if($i=="from") print $(i+1)}' | sort | uniq -c | sort -rn | head -5)
            IP_LIST="$IP_LIST$IP\n"
        fi
    done

    if [ "$TOTAL" -gt 0 ]; then
        IN_USE=1
        REASONS="$REASONS\n    - logs: $TOTAL login events recorded using this key"
        echo "    [ACTIVE] $TOTAL occurrences of this fingerprint in auth logs."
        echo "    Last matching line:"
        echo "        $LASTLINE"
        echo "    Source IPs (Accepted logins):"
        echo -e "$IP_LIST" | sed '/^$/d' | sed 's/^/        /'
    else
        echo "    NO logins recorded with this fingerprint within the log retention period."
    fi
fi

#----------------------------------------------------------
# 4. sshd INFO (for rotation planning)
#----------------------------------------------------------
echo
echo "--- 4. sshd INFO ---"
SSHD_CONF=$(grep -E "^\s*(PermitRootLogin|PubkeyAuthentication|AuthorizedKeysFile)" /etc/ssh/sshd_config 2>/dev/null | sed 's/^/    /')
echo "${SSHD_CONF:-    (no explicit settings in sshd_config)}"
SSH_SERVICE=$(systemctl is-active sshd 2>/dev/null || systemctl is-active ssh 2>/dev/null)
echo "    sshd service: ${SSH_SERVICE:-unknown}"

#----------------------------------------------------------
# VERDICT
#----------------------------------------------------------
echo
echo "=========================================================="
echo "[$HOSTNAME_N] VERDICT: $KEY"
echo "=========================================================="
if [ "$IN_USE" = 1 ]; then
    echo "STATUS: STILL IN USE"
    echo -e "$REASONS"
    echo ">> Do NOT remove before rotation. Deploy a new key, verify login, then revoke the old one."
else
    echo "STATUS: NO EVIDENCE OF USAGE"
    echo ">> Technically safe to remove, BUT:"
    echo "   - check the log retention window above (older logs may already have rotated)"
    echo "   - confirm with the owning team whether any external process uses this key"
    echo "   - perform removal in a change window with fallback access (console/IPMI/bastion)"
fi
echo "=========================================================="
echo
