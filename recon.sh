#!/bin/bash
read -p "Enter hostname (from /etc/hosts): " HOST
WORDLIST="/usr/share/wordlists/dirb/common.txt"
EXTENSIONS="php,txt,html,bak,old,zip,env"
WORDLIST2="/usr/share/wordlists/seclists/Discovery/DNS/subdomains-top1million-20000.txt"

# -----------------------------
# 0. Setup: Create and enter scanning directory FIRST
# -----------------------------
mkdir -p scanning
cd scanning || exit

WORKDIR="$(pwd)"
echo "[+] Working directory: $WORKDIR"
echo "[+] Recon started on $HOST" | tee summary.txt
echo "==================================" >> summary.txt

# -----------------------------
# 1. Fast TCP port scan (synchronous — must finish before anything else)
# -----------------------------
echo "[+] Running fast TCP scan..."
nmap -Pn -p- --min-rate 5000 -T4 "$HOST" -oN nmap_fast.txt

if [[ ! -s nmap_fast.txt ]]; then
  echo "[-] nmap_fast.txt is empty. Did nmap fail? Aborting." | tee -a summary.txt
  exit 1
fi

PORTS=$(grep "/tcp" nmap_fast.txt | grep open | cut -d'/' -f1 | tr '\n' ',' | sed 's/,$//')
WEB_PORTS=$(grep -Ei "open.*(http|ssl|www)" nmap_fast.txt | awk -F/ '{print $1}')
HTTPS_PORTS=$(grep -Ei "open.*(https|ssl)" nmap_fast.txt | awk -F/ '{print $1}')
DNS_OPEN=$(grep "^53/tcp open" nmap_fast.txt)

# Debug output so you can always see what was detected
echo "[+] Open TCP ports : '${PORTS}'"    | tee -a summary.txt
echo "[+] Web ports      : '${WEB_PORTS}'"| tee -a summary.txt

if [[ -z "$PORTS" ]]; then
  echo "[-] WARNING: No open TCP ports found. Only UDP scan will run." | tee -a summary.txt
fi

# -----------------------------
# 2. tmux session setup
# -----------------------------
echo "[+] Setting up tmux session..."

# open_window: writes commands to a temp script, then runs it in a new tmux window
# This avoids ALL quoting/newline issues with send-keys
open_window() {
  local NAME="$1"
  local SCRIPT="$WORKDIR/._win_${NAME}.sh"

  # Write the command block to a temp script file
  cat > "$SCRIPT" << 'HEREDOC_SENTINEL'
#!/bin/bash
HEREDOC_SENTINEL

  # Append the actual command (safely, no quoting concerns)
  echo "$2" >> "$SCRIPT"
  chmod +x "$SCRIPT"

  if [[ -n "$TMUX" ]]; then
    tmux new-window -n "$NAME"
    tmux send-keys -t "$NAME" "bash $SCRIPT; echo '[window done]'; exec bash" C-m
  else
    tmux new-window -t "recon" -n "$NAME"
    tmux send-keys -t "recon:$NAME" "bash $SCRIPT; echo '[window done]'; exec bash" C-m
  fi
}

if [[ -n "$TMUX" ]]; then
  echo "[+] Running inside tmux — opening windows in current session"
else
  tmux kill-session -t recon 2>/dev/null
  tmux new-session -d -s recon
  echo "[+] Created new tmux session: recon"
fi

# -----------------------------
# 3. UDP Scan
# -----------------------------
open_window "udp" "
echo '[+] Running UDP scan' >> $WORKDIR/summary.txt
nmap -Pn -sU -sV -p 53,69,123,161,500 --top-ports 200 -T5 $HOST -oN $WORKDIR/nmap_udp.txt
echo '[+] UDP scan completed' >> $WORKDIR/summary.txt
"

# -----------------------------
# 4. Full TCP service scan
# -----------------------------
if [[ -n "$PORTS" ]]; then
  open_window "nmap_full" "
echo '[+] Starting nmap full scan on ports: $PORTS' >> $WORKDIR/summary.txt
nmap -Pn -sC -sV -p $PORTS -vv $HOST -oN $WORKDIR/nmap_full.txt \
  && echo '[+] nmap full scan completed' >> $WORKDIR/summary.txt \
  || echo '[-] nmap full scan failed' >> $WORKDIR/summary.txt
"
else
  echo "[-] Skipping nmap_full — no open ports." >> summary.txt
fi

# -----------------------------
# 5. DNS recon
# -----------------------------
if [[ -n "$DNS_OPEN" ]]; then
  open_window "dns" "
dig any $HOST @$HOST +noall +answer | tee $WORKDIR/dig_dns.txt
echo '[+] DNS recon completed' >> $WORKDIR/summary.txt
"
  echo "[+] DNS service detected (TCP 53)" >> summary.txt
fi

# -----------------------------
# 6. Web recon per port
# -----------------------------
for PORT in $WEB_PORTS; do
  PROTO="http"
  if echo "$HTTPS_PORTS" | grep -qw "$PORT"; then
    PROTO="https"
  fi

  # --- Main web recon window ---
  open_window "web_$PORT" "
echo '' >> $WORKDIR/summary.txt
echo '[+] Web Recon on $PROTO://$HOST:$PORT' >> $WORKDIR/summary.txt

# Headers
curl -s -I $PROTO://$HOST:$PORT | tee $WORKDIR/headers_$PORT.txt
grep -Ei 'server|powered|cookie|location|www-authenticate|x-' $WORKDIR/headers_$PORT.txt >> $WORKDIR/summary.txt

# Tech fingerprint
whatweb $PROTO://$HOST:$PORT | tee $WORKDIR/whatweb_$PORT.txt

# Custom wordlist + email harvesting (background)
cewl $PROTO://$HOST:$PORT -w $WORKDIR/cewl_words_$PORT.txt -d 2 -m 5 &
cewl $PROTO://$HOST:$PORT --email -e --email_file $WORKDIR/cewl_emails_$PORT.txt -d 2 &

# Email extraction from page source
curl -s $PROTO://$HOST:$PORT/ \
  | grep -Eio '([a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+\.[a-zA-Z]{2,})' \
  | sort -u > $WORKDIR/emails_$PORT.txt

# Soft 404 detection
curl -s $PROTO://$HOST:$PORT/ > $WORKDIR/root_$PORT.html
curl -s $PROTO://$HOST:$PORT/this_should_not_exist_123 > $WORKDIR/random_$PORT.html
diff $WORKDIR/root_$PORT.html $WORKDIR/random_$PORT.html > $WORKDIR/diff_$PORT.txt

# ReconSpider
reconspider $PROTO://$HOST:$PORT
[ -f results.json ] && mv results.json $WORKDIR/reconspider_$PORT.json

wait

echo '' >> $WORKDIR/summary.txt
echo '[Email Addresses Found]' >> $WORKDIR/summary.txt
[ -s $WORKDIR/cewl_emails_$PORT.txt ] && cat $WORKDIR/cewl_emails_$PORT.txt >> $WORKDIR/summary.txt
[ -s $WORKDIR/emails_$PORT.txt ]      && cat $WORKDIR/emails_$PORT.txt      >> $WORKDIR/summary.txt
echo '[+] Web recon completed on port $PORT' >> $WORKDIR/summary.txt
"

  # --- Directory fuzzing ---
  open_window "ffuf_dir_$PORT" "
echo '[+] Starting directory fuzzing on port $PORT' >> $WORKDIR/summary.txt
ffuf -w $WORDLIST \
     -u $PROTO://$HOST:$PORT/FUZZ \
     -fc 404 -c -e .$EXTENSIONS \
     -o $WORKDIR/ffuf_dirs_$PORT.json
echo '' >> $WORKDIR/summary.txt
echo '[Discovered Paths]' >> $WORKDIR/summary.txt
jq -r '.results[] | \"[\(.status)] \(.url)\"' $WORKDIR/ffuf_dirs_$PORT.json 2>/dev/null >> $WORKDIR/summary.txt
jq -r '.results[] | .url' $WORKDIR/ffuf_dirs_$PORT.json 2>/dev/null > $WORKDIR/discovered_urls_$PORT.txt
echo \"[+] Found \$(wc -l < $WORKDIR/discovered_urls_$PORT.txt) paths\" >> $WORKDIR/summary.txt
"

  # --- Vhost fuzzing ---
  open_window "ffuf_vhost_$PORT" "
echo '[+] Starting vhost fuzzing on port $PORT' >> $WORKDIR/summary.txt
ffuf -w $WORDLIST2 \
     -u $PROTO://$HOST:$PORT/ \
     -H 'Host: FUZZ.$HOST' \
     -ac -mc all -c \
     -o $WORKDIR/ffuf_vhost_$PORT.json
echo '' >> $WORKDIR/summary.txt
echo '[Discovered Virtual Hosts]' >> $WORKDIR/summary.txt
jq -r '.results[] | \"[\(.status)] \(.input.FUZZ).$HOST (\(.words) words)\"' $WORKDIR/ffuf_vhost_$PORT.json 2>/dev/null >> $WORKDIR/summary.txt
jq -r '.results[] | .input.FUZZ + \".$HOST\"' $WORKDIR/ffuf_vhost_$PORT.json 2>/dev/null > $WORKDIR/discovered_vhosts_$PORT.txt
echo \"[+] Found \$(wc -l < $WORKDIR/discovered_vhosts_$PORT.txt) vhosts\" >> $WORKDIR/summary.txt
"

  # --- Nikto ---
  open_window "nikto_$PORT" "
echo '[+] Starting nikto on port $PORT' >> $WORKDIR/summary.txt
nikto -h $PROTO://$HOST:$PORT | tee $WORKDIR/nikto_$PORT.txt
echo '[+] Nikto done on port $PORT' >> $WORKDIR/summary.txt
"
done

# -----------------------------
# 7. Summary footer
# -----------------------------
{
  echo ""
  echo "Review priority:"
  echo "1. summary.txt"
  echo "2. nmap_fast.txt / nmap_full.txt"
  echo "3. nmap_udp.txt"
  echo "4. headers_PORT.txt / whatweb_PORT.txt"
  echo "5. reconspider_PORT.json"
  echo "6. ffuf_dirs_PORT.json / discovered_urls_PORT.txt"
  echo "7. ffuf_vhost_PORT.json / discovered_vhosts_PORT.txt"
  echo "8. cewl_emails_PORT.txt / emails_PORT.txt"
  echo "9. nikto_PORT.txt"
  echo "10. diff_PORT.txt"
} >> summary.txt

echo "[+] All scans launched."
echo "[+] Use Ctrl+b w to list windows, Ctrl+b n/p to navigate"

if [[ -z "$TMUX" ]]; then
  tmux attach -t recon
fi