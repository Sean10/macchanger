# macchanger
macchanger for macOS - Spoof / Fake MAC address  
**NEW:** Updated to support macOS Sonoma 14.4+

![](macchanger_1.png?raw=true)

## Installation
The easiest way to install `macchanger` is via [Homebrew](https://brew.sh/).
```
brew install macchanger
```

Alternatively, you can compile `macchanger` yourself:
```sh
git clone https://github.com/shilch/macchanger
cd macchanger
sudo make install
```

## Usage
Type `sudo macchanger`:
```
Usage: macchanger [option] [device]
Options:
 -r, --random           Generates a random MAC and sets it
 -m, --mac MAC          Set a custom MAC address, e.g. macchanger -m aa:bb:cc:dd:ee:ff en0
 -p, --permanent        Resets the MAC address to the permanent
 -s, --show             Shows the current MAC address
 -v, --version          Prints version
 -S, --save             Save current MAC to config file (combine with -m to save specific MAC)
 -c, --config           Apply MAC from config file
 -i, --install-daemon   Install launchd daemon for auto-start at boot
 -u, --uninstall-daemon Remove launchd daemon
```

### Set custom MAC
`sudo macchanger -m aa:bb:cc:dd:ee:ff en0`

### Set random MAC
`sudo macchanger -r en0`

### Reset to permanent MAC
`sudo macchanger -p en0`

## Persist MAC After Reboot

By default, MAC address changes are lost after reboot. To automatically restore your MAC at boot:

### Using Homebrew Services (Recommended)

```bash
# Step 1: Set your desired MAC address
sudo macchanger -m aa:bb:cc:dd:ee:ff en0

# Step 2: Save the configuration
sudo macchanger --save en0

# Step 3: Enable auto-start
sudo brew services start macchanger

# To disable:
sudo brew services stop macchanger
```

### Using launchd (Manual Install)

```bash
# Step 1: Set your desired MAC address
sudo macchanger -m aa:bb:cc:dd:ee:ff en0

# Step 2: Save the configuration
sudo macchanger --save en0

# Step 3: Install the daemon
sudo macchanger --install-daemon

# To disable:
sudo macchanger --uninstall-daemon
```

The configuration file is stored at `/opt/homebrew/etc/macchanger.conf` (Homebrew) or `/usr/local/etc/macchanger.conf` (manual install).

## To do
- ~~Option to set MAC address at startup~~ ✓
- Add Manufacturer info

## License
macchanger is licensed under GPLv2.
