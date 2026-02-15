
#!/bin/bash

echo "Use NON root user and sudo to run it"

cd ~/Downaloads
wget -qO - https://download.sublimetext.com/sublimehq-pub.gpg | sudo gpg --dearmor -o /usr/share/keyrings/sublimehq-archive.gpg



echo "deb [signed-by=/usr/share/keyrings/sublimehq-archive.gpg] https://download.sublimetext.com/ apt/stable/" | sudo tee /etc/apt/sources.list.d/sublime-text.list



sudo apt update

sudo apt install sublime-text -y


sudo apt install terminator -y


wget https://raw.githubusercontent.com/Crypto-Cat/CTF/refs/heads/main/auto_ghidra.py
echo "alias ghidra_auto='python3 /root/Downloads/auto_ghidra.py'" >> ~/.zshrc




# Installing Dependencies
echo "Installing Dependencies..."
sudo apt update
sudo apt install git wget openjdk-21-jre -y

# Cloning
git clone https://github.com/xiv3r/Burpsuite-Professional.git 
cd Burpsuite-Professional

# Download Burpsuite Professional
echo "Downloading Burp Suite Professional Latest..."
version=2025
wget -O burpsuite_pro_v$version.jar https://github.com/xiv3r/Burpsuite-Professional/releases/download/burpsuite-pro/burpsuite_pro_v$version.jar

# Execute Key Generator
echo "Starting Key loader.jar..."
(java -jar loader.jar) &

# Execute Burpsuite Professional
echo "Executing Burpsuite Professional..."
echo "java --add-opens=java.desktop/javax.swing=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/jdk.internal.org.objectweb.asm=ALL-UNNAMED --add-opens=java.base/jdk.internal.org.objectweb.asm.tree=ALL-UNNAMED --add-opens=java.base/jdk.internal.org.objectweb.asm.Opcodes=ALL-UNNAMED -javaagent:$(pwd)/loader.jar -noverify -jar $(pwd)/burpsuite_pro_v$version.jar &" > burpsuitepro
chmod +x burpsuitepro
cp burpsuitepro /bin/burpsuitepro

#for the recon.sh
sudo apt update && sudo apt install -y \
nmap \
nikto \
ffuf \
cewl \
dnsutils \
whatweb \
tmux \
jq \
curl

apt -y install seclists

echo "alias recon='/root/recon.sh'" >> ~/.zshrc
echo "htb='openvpn /root/htbopenvpn.ovpn'" >> ~/.zshrc
echo "revstable='subl /root/stablizer.txt'" >> ~/.zshrc

