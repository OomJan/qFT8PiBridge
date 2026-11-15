# Copy to config.sh, edit locally, and keep config.sh out of Git.
# This is trusted Bash code: use quotes and never use an untrusted config file.
AP_SSID='qFT8-Bridge'
AP_PASSWORD='CHANGE_ME_hotspot_password'
CLIENT_SSID='CHANGE_ME_router_name'
CLIENT_PASSWORD='CHANGE_ME_router_password'
BRIDGE_NAME='IC7300-Bridge'
BRIDGE_PASSWORD='CHANGE_ME_bridge_password'
TX_VOLUME=70
COUNTRY='DE'
AP_IP='192.168.50.1'
WIFI_IF='wlan0'

# SH1106 128x64 on I2C bus 1, address 0x3C (some modules use 0x3D).
OLED_I2C_BUS=1
OLED_I2C_ADDRESS=0x3C
# Seconds before dimming; 0 disables dimming. Contrast range: 0 to 255.
OLED_DIM_AFTER=60
OLED_CONTRAST=96
OLED_DIM_CONTRAST=8
