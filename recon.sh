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

echo "[+] Working directory: $(pwd)"
echo "[+] Recon started on $HOST" | tee summary.txt
echo "==================================" >> summary.txt

# -----------------------------
# 1. Fast TCP port scan
# -----------------------------
echo "[+] Running fast TCP scan..."
nmap -p- --min-rate 5000 -T4 "$HOST" -oN nmap_fast.txt
PORTS=$(grep open nmap_fast.txt | cut -d'/' -f1 | tr '\n' ',' | sed 's/,$//')
WEB_PORTS=$(grep -Ei "open.*(http|ssl|www)" nmap_fast.txt | awk -F/ '{print $1}')
HTTPS_PORTS=$(grep -Ei "open.*(https|ssl)" nmap_fast.txt | awk -F/ '{print $1}')
DNS_OPEN=$(grep "^53/tcp open" nmap_fast.txt)

echo "[+] Open TCP ports: $PORTS" >> summary.txt
echo "[+] Web ports detected: $WEB_PORTS" >> summary.txt

# -----------------------------
# 2. Start tmux session (kill old one first)
# -----------------------------
echo "[+] Starting tmux session..."
tmux kill-session -t recon 2>/dev/null
tmux new-session -d -s recon

# -----------------------------
# 3. UDP Scan
# -----------------------------
tmux new-window -t recon -n udp
tmux send-keys -t recon:udp \
"cd $(pwd) && \
 echo '[+] Running UDP scan' >> summary.txt && \
 nmap -sU -sV -p 53,69,123,161,500 --top-ports 200 -T5 $HOST -oN nmap_udp.txt && \
 echo '[+] UDP scan completed (see nmap_udp.txt)' >> summary.txt" C-m

# -----------------------------
# 4. Full TCP service scan
# -----------------------------
tmux new-window -t recon -n nmap
tmux send-keys -t recon:nmap \
"cd $(pwd) && nmap -sC -sV -p $PORTS -vv $HOST -oN nmap_full.txt" C-m

# -----------------------------
# 5. DNS recon (TCP 53 only)
# -----------------------------
if [[ -n "$DNS_OPEN" ]]; then
  tmux new-window -t recon -n dns
  tmux send-keys -t recon:dns \
  "cd $(pwd) && dig any $HOST @$HOST +noall +answer | tee dig_dns.txt" C-m
  echo "[+] DNS service detected (TCP 53)" >> summary.txt
fi

# -----------------------------
# 6. Web recon per port
# -----------------------------
for PORT in $WEB_PORTS; do
  # Determine protocol
  PROTO="http"
  if echo "$HTTPS_PORTS" | grep -qw "$PORT"; then
    PROTO="https"
  fi
  
  # Main web recon window
  tmux new-window -t recon -n web_$PORT
  tmux send-keys -t recon:web_$PORT \
  "cd $(pwd)
  echo '' >> summary.txt
  echo '[+] Web Recon on $PROTO://$HOST:$PORT' >> summary.txt
  
  # Headers
  curl -s -I $PROTO://$HOST:$PORT | tee headers_$PORT.txt
  grep -Ei 'server|powered|cookie|location|www-authenticate|x-' headers_$PORT.txt >> summary.txt
  
  # Technology fingerprinting
  whatweb $PROTO://$HOST:$PORT | tee whatweb_$PORT.txt
  
  # CeWL: Custom wordlist generation
  cewl $PROTO://$HOST:$PORT -w cewl_words_$PORT.txt -d 2 -m 5 &
  
  # CeWL: Email harvesting
  cewl $PROTO://$HOST:$PORT --email -e --email_file cewl_emails_$PORT.txt -d 2 &
  
  # Email extraction from page source
  curl -s $PROTO://$HOST:$PORT/ | grep -Eio '([a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+\.[a-zA-Z]{2,})' | sort -u > emails_$PORT.txt
  
  # Quick page analysis
  curl -s $PROTO://$HOST:$PORT/ > root_$PORT.html
  curl -s $PROTO://$HOST:$PORT/this_should_not_exist_123 > random_$PORT.html
  diff root_$PORT.html random_$PORT.html > diff_$PORT.txt
  
  # Wait for CeWL jobs
  wait
  
  # Email summary
  echo '' >> summary.txt
  echo '[Email Addresses Found]' >> summary.txt
  if [ -f cewl_emails_$PORT.txt ] && [ -s cewl_emails_$PORT.txt ]; then
    cat cewl_emails_$PORT.txt >> summary.txt
  fi
  if [ -f emails_$PORT.txt ] && [ -s emails_$PORT.txt ]; then
    cat emails_$PORT.txt >> summary.txt
  fi
  
  echo '[+] Web recon (non-ffuf) completed on port $PORT' >> summary.txt
  " C-m
  
  # Separate window for directory fuzzing
  tmux new-window -t recon -n ffuf_dir_$PORT
  tmux send-keys -t recon:ffuf_dir_$PORT \
  "cd $(pwd) && \
   echo '[+] Starting directory fuzzing on port $PORT' && \
   ffuf -w $WORDLIST -u $PROTO://$HOST:$PORT/FUZZ -fc 404 -c -e .$EXTENSIONS -o ffuf_dirs_$PORT.json && \
   echo '[+] Directory fuzzing completed on port $PORT' >> summary.txt && \
   echo '' >> summary.txt && \
   echo '[Discovered Paths]' >> summary.txt && \
   jq -r '.results[] | \"[\(.status)] \(.url)\"' ffuf_dirs_$PORT.json 2>/dev/null >> summary.txt && \
   jq -r '.results[] | .url' ffuf_dirs_$PORT.json 2>/dev/null > discovered_urls_$PORT.txt && \
   echo '[+] Found' \$(wc -l < discovered_urls_$PORT.txt) 'paths (saved to discovered_urls_$PORT.txt)' >> summary.txt" C-m
  
  # Separate window for vhost fuzzing
# Separate window for vhost fuzzing
  tmux new-window -t recon -n ffuf_vhost_$PORT
  tmux send-keys -t recon:ffuf_vhost_$PORT \
  "cd $(pwd) && \
   echo '[+] Starting vhost fuzzing on port $PORT' && \
   ffuf -w $WORDLIST2 -u $PROTO://$HOST:$PORT/ -H 'Host: FUZZ.$HOST' -ac -mc all -c -o ffuf_vhost_$PORT.json && \
   echo '[+] Vhost fuzzing completed' >> summary.txt && \
   echo '' >> summary.txt && \
   echo '[Discovered Virtual Hosts]' >> summary.txt && \
   jq -r '.results[] | \"[\(.status)] \(.input.FUZZ).$HOST (\(.words) words)\"' ffuf_vhost_$PORT.json 2>/dev/null >> summary.txt && \
   jq -r '.results[] | .input.FUZZ + \".\" + \"$HOST\"' ffuf_vhost_$PORT.json 2>/dev/null > discovered_vhosts_$PORT.txt && \
   echo '[+] Found' \$(wc -l < discovered_vhosts_$PORT.txt) 'vhosts (saved to discovered_vhosts_$PORT.txt)' >> summary.txt" C-m
    
  # Separate window for nikto (can be slow)
  tmux new-window -t recon -n nikto_$PORT
  tmux send-keys -t recon:nikto_$PORT \
  "cd $(pwd) && \
   echo '[+] Starting nikto scan on port $PORT' && \
   nikto -h $PROTO://$HOST:$PORT | tee nikto_$PORT.txt && \
   echo '[+] Nikto scan completed on port $PORT' >> summary.txt" C-m
done

# -----------------------------
# 7. Final summary
# -----------------------------
echo "" >> summary.txt
echo "Review priority:" >> summary.txt
echo "1. summary.txt" >> summary.txt
echo "2. nmap_fast.txt / nmap_full.txt" >> summary.txt
echo "3. nmap_udp.txt" >> summary.txt
echo "4. headers_PORT.txt" >> summary.txt
echo "5. ffuf_dirs_PORT.json" >> summary.txt
echo "6. ffuf_vhost_PORT.json" >> summary.txt
echo "7. cewl_emails_PORT.txt / emails_PORT.txt" >> summary.txt
echo "8. nikto_PORT.txt" >> summary.txt
echo "9. diff_PORT.txt" >> summary.txt

echo "[+] All scans running in tmux. Attaching to session..."
echo "[+] Use Ctrl+b w to see all windows"
echo "[+] Use Ctrl+b n/p to navigate between windows"
tmux attach -t recon