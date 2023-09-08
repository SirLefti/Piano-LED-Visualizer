#!/bin/bash

# Function to display error message and exit
display_error() {
  echo "Error: $1" >&2
  exit 1
}

# Function to execute a command and handle errors, with optional internet connectivity check
execute_command() {
  local check_internet="$2"  # Check for internet if this argument is provided

  echo "Executing: $1"

  if [ "$check_internet" = "check_internet" ]; then
    local max_retries=18  # Total number of retries (18 retries * 10 seconds = 3 minutes)
    local retry_interval=10  # Retry interval in seconds

    for ((attempt = 1; attempt <= max_retries; attempt++)); do
      # Check for internet connectivity
      if ping -q -c 1 -W 1 google.com &>/dev/null; then
        # Internet is available, execute the command
        eval "$1"
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
          return 0  # Command executed successfully
        else
          echo "Command failed with exit code $exit_code."
          sleep $retry_interval  # Wait before retrying
        fi
      else
        echo "Internet not available, retrying in $retry_interval seconds (Attempt $attempt/$max_retries)..."
        sleep $retry_interval  # Wait before retrying
      fi
    done

    echo "Command failed after $((max_retries * retry_interval)) seconds of retries."
    exit 1  # Exit the script after multiple unsuccessful retries
  else
    eval "$1"  # Execute the command without internet connectivity check
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
      echo "Command failed with exit code $exit_code."
    fi
  fi
}



# Function to update the OS
update_os() {
  execute_command "sudo apt-get update" "check_internet"
  execute_command "sudo apt-get upgrade -y"
}

# Function to create and configure the autoconnect script
configure_autoconnect_script() {
  # Create connectall.py file
  cat <<EOF | sudo tee /usr/local/bin/connectall.py > /dev/null
#!/usr/bin/python3
import subprocess

ports = subprocess.check_output(["aconnect", "-i", "-l"], text=True)
port_list = []
client = "0"
for line in str(ports).splitlines():
    if line.startswith("client "):
        client = line[7:].split(":",2)[0]
        if client == "0" or "Through" in line:
            client = "0"
    else:
        if client == "0" or line.startswith('\t'):
            continue
        port = line.split()[0]
        port_list.append(client+":"+port)
for source in port_list:
    for target in port_list:
        if source != target:
            subprocess.call("aconnect %s %s" % (source, target), shell=True)
EOF
  execute_command "sudo chmod +x /usr/local/bin/connectall.py"

  # Create udev rules file
  echo 'ACTION=="add|remove", SUBSYSTEM=="usb", DRIVER=="usb", RUN+="/usr/local/bin/connectall.py"' | sudo tee -a /etc/udev/rules.d/33-midiusb.rules > /dev/null

  # Reload services
  execute_command "sudo udevadm control --reload"
  execute_command "sudo service udev restart"

  # Create midi.service file
  cat <<EOF | sudo tee /lib/systemd/system/midi.service > /dev/null
[Unit]
Description=Initial USB MIDI connect

[Service]
ExecStart=/usr/local/bin/connectall.py

[Install]
WantedBy=multi-user.target
EOF

  # Reload daemon and enable service
  execute_command "sudo systemctl daemon-reload"
  execute_command "sudo systemctl enable midi.service"
  execute_command "sudo systemctl start midi.service"
}

# Function to enable SPI interface
enable_spi_interface() {
  # Edit config.txt file to enable SPI interface
  execute_command "sudo sed -i '$ a\dtparam=spi=on' /boot/config.txt"
}

# Function to install required packages
install_packages() {
  execute_command "sudo apt-get install -y ruby git python3-pip autotools-dev libtool autoconf libasound2-dev libusb-dev libdbus-1-dev libglib2.0-dev libudev-dev libical-dev libreadline-dev python-dev libatlas-base-dev libopenjp2-7 libtiff5 libjack0 libjack-dev libasound2-dev fonts-freefont-ttf gcc make build-essential python-dev git scons swig libavahi-client3 abcmidi dnsmasq hostapd" "check_internet"
}

# Function to disable audio output
disable_audio_output() {
  echo 'blacklist snd_bcm2835' | sudo tee -a /etc/modprobe.d/snd-blacklist.conf > /dev/null
  sudo sed -i 's/dtparam=audio=on/#dtparam=audio=on/' /boot/config.txt
}

# Function to install RTP-midi server
install_rtpmidi_server() {
  execute_command "cd /home/"
  execute_command "sudo wget https://github.com/davidmoreno/rtpmidid/releases/download/v21.11/rtpmidid_21.11_armhf.deb" "check_internet"
  execute_command "sudo dpkg -i rtpmidid_21.11_armhf.deb"
}

# Function to create Hot-Spot
create_hotspot() {
  echo 'interface wlan0 static ip_address=192.168.4.1/24' | sudo tee --append /etc/dhcpcd.conf > /dev/null
  sudo mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
  sudo systemctl daemon-reload
  sudo systemctl restart dhcpcd
  echo 'interface=wlan0 dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h' | sudo tee --append /etc/dnsmasq.conf > /dev/null

  hotspot_config_content=$(cat <<EOT
interface=wlan0
driver=nl80211
ssid=PianoLEDVisualizer
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=visualizer
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOT
  )

  # Use echo to send the content to the file with sudo
  echo "$hotspot_config_content" | sudo tee /etc/hostapd/hostapd.conf > /dev/null

  echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' | sudo tee --append /etc/default/hostapd > /dev/null
  execute_command "sudo systemctl unmask hostapd"
  execute_command "sudo systemctl enable hostapd && sudo systemctl enable dnsmasq"
}

configure_network_interfaces() {
  # Edit /etc/network/interfaces file
  local interfaces_file="/etc/network/interfaces"
  local interfaces_config="
auto wlan0
iface wlan0 inet manual
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
"

  echo "$interfaces_config" | sudo tee -a "$interfaces_file" > /dev/null
  echo "Network interfaces configuration added to $interfaces_file."
}

# Function to install Piano-LED-Visualizer
install_piano_led_visualizer() {
  execute_command "cd /home/"
  execute_command "sudo git clone https://github.com/onlaj/Piano-LED-Visualizer" "check_internet"
  execute_command "cd Piano-LED-Visualizer"
  execute_command "sudo pip3 install -r requirements.txt" "check_internet"
  execute_command "sudo raspi-config nonint do_boot_behaviour B2"
  cat <<EOF | sudo tee /lib/systemd/system/visualizer.service > /dev/null
[Unit]
Description=Piano LED Visualizer
After=network-online.target
Wants=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
ExecStart=sudo python3 /home/Piano-LED-Visualizer/visualizer.py
Type=simple
User=plv
Group=plv
EOF
  execute_command "sudo systemctl daemon-reload"
  execute_command "sudo systemctl enable visualizer.service"
  execute_command "sudo systemctl start visualizer.service"

  execute_command "sudo chmod a+rwxX -R /home/Piano-LED-Visualizer/"

  execute_command "sudo chmod +x /home/Piano-LED-Visualizer/disable_ap.sh"
  execute_command "sudo chmod +x /home/Piano-LED-Visualizer/enable_ap.sh"

  execute_command "sudo /home/Piano-LED-Visualizer/enable_ap.sh"
  echo "Finishing installation, restart in 60 seconds"
  sleep 60
  # Reboot Raspberry Pi
  execute_command "sudo reboot"
}

echo "
#    _____  _                        _       ______  _____
#   |  __ \\(_)                      | |     |  ____||  __ \\
#   | |__) |_   __ _  _ __    ___   | |     | |__   | |  | |
#   |  ___/| | / _\` || '_ \\  / _ \\  | |     |  __|  | |  | |
#   | |    | || (_| || | | || (_) | | |____ | |____ | |__| |
#   |_|    |_| \\__,_||_| |_| \\___/  |______||______||_____/
#   __      __ _                     _  _
#   \\ \\    / /(_)                   | |(_)
#    \\ \\  / /  _  ___  _   _   __ _ | | _  ____ ___  _ __
#     \\ \\/ /  | |/ __|| | | | / _\` || || ||_  // _ \\| '__|
#      \\  /   | |\\__ \\| |_| || (_| || || | / /|  __/| |
#       \\/    |_||___/ \\__,_| \\__,_||_||_|/___|\\___||_|
#
# Autoinstall script
# - by Onlaj
"

# Main script execution
update_os
configure_autoconnect_script
enable_spi_interface
install_packages
disable_audio_output
install_rtpmidi_server
install_piano_led_visualizer
configure_network_interfaces
create_hotspot