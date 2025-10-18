# MacBook Usage Monitor

## Design

The project is composed of two main parts: A UsageMonitor and a UsageMonitorApp. 


Battery Stats to keep track of:
Short term: Trigger on battery percent change
- Current battery percentage ("CurrentCapacity", 0-2e7) and per-cell discharge ("PresentDOD", 3-tuple of 0-2e7)
- Current battery voltage ("Voltage", 0-2e15) and per-cell voltage (CellVoltage, 3-tuple of 0-2e13)
- Current battery capacity ("AppleRawCurrentCapacity", 0-2e13)
- Amperage ("Amperage" -2e13-2e13)

Long term: Trigger on IsCharging
- Is charging ("IsCharging" / "ExternalConnected", 0-1)
- Cycle Count ("CycleCount", 0-2e14)
- Current Maximum Capacity ("AppleRawMaxCapacity", 0-2e13)
- Resistance ("WeightedRa", 3-tuple of 0-2^8)
- per-cell capacity ("Qmax", 3-tuple of 0-2e13)

Constant: read when needed
- Design Capacity (constant "DesignCapacity", 0-2e13)

The UsageMonitor should subscribe to system events, or periodically check for:
- When the Battery Percentage changes
- When the user begins charging their computer
- When the user locks or unlocks the device
- When the Charge Cycle increments
- When the battery health decreases
- The keys that are being pressed at any given moment (The user will first give accessibility and input monitoring permissions)

The UsageMonitor should batch writes to an underlying file, or multiple files that will track this information.

One file should contain Entry Time, Battery Percent, Power Source (Charger or Battery): BatteryCharge.csv

One file should contain Entry Time, Screen state (Lock or Unlock): ScreenState.csv

One file should contain Entry Time, Battery Health, Charge Cycle Count: BatteryHealth.csv

A new entry should be appended to the file every time any of the fields (other than Entry time) change (ie: if the computer is locked, if the charger is plugged in, if the battery percent increases or decreases, etc.)

One file should contain a mapping from Macbook Key codes to number of presses for that key: KeyFrequency.json

This file should be updated continuously as keys are pressed, and a snapshot of it should be saved sometime every day.

For all files, writes can be batched as needed to increases efficiency.

However, shutdown handling should be graceful, and the code should reduce the number of entries lost. In addition, the code should be able to add a Use State Lock entry right before shutting down, and an Unlock entry when the code first starts up again after a shutdown.

Hence, the code should be a script that is executed via launchagents and is kept alive while the macbook is on. 

The UsageMonitor app should display all collected information, including the extensive battery logs. This will require it to read in the file every time the app is started, either by directly reading the file, or by requesting the UsageMonitor, if UsageMonitor exposes an interface. The only process writing to the files should be UsageMonitor, the App should only read, but concurrency issues should be avoided by design.



## Motivation
The purpose of this code is to allow one to track various hardward utilization metrics for their MacBook. In particular, this code tracks screen time by logging all sleep/wake and screen lock/unlock events. In addition it tracks battery usage by periodically logging the current battery percentage, the battery health, the current number of charge cycles, and whether the MacBook is currently charging. Finally, the code also tracks keystrokes, storing the frequency of usage for each key.

In particular, battery usage metrics are queried once every minute, while keystrokes and screen activity are monitored on event, with a default screen log every 5 minutes. The results are written to files every 10 minutes, or whenever the code is terminated, or when the MacBook is put to sleep.

## Usage
- Compile `UsageMonitor.swift` via `swiftc UsageMonitor.swift -o UsageMonitor`
- Create a folder under the user library `~/Library/UsageMonitor`, and place the compiled executable into that folder
- Copy `UsageMonitorLaunchAgentCommand.xml` to `~/Library/LaunchAgents` and rename the file `com.user.usagemonitor.plist`
- Note that you may need to update file paths within `UsageMonitorLaunchAgentCommand.xml` to accurately reflect your setup
- Ensure the LaunchAgent specification is properly formatted via `plutil ~/Library/LaunchAgents/com.user.usagemonitor.plist`
- Enter settings and give `UsageMonitor` permission under Accessibility and Input Monitoring
- Add `UsageMonitor` as a LaunchAgent script via `launchctl load ~/Library/LaunchAgents/com.user.usagemonitor.plist` and `launchctl start com.user.usagemonitor`
- Stop the `UsageMonitor` with `launchctl unload ~/Library/LaunchAgents/com.user.usagemonitor.plist`
- Add a Maintenance script that periodically cleans the logs on days that are multiples of 5, and saves backup copies of the files.
- Compile the Maintenance script via `swiftc UsageMonitorMaintenance.swift -o UsageMonitorMaintenance`
- Copy `UsageMonitorMaintenanceLaunchAgentCommand.xml` to `~/Library/LaunchAgents` and rename the file `com.user.usagemonitormaintenance.plist`
- Note that you may need to update file paths within `UsageMonitorMaintenanceLaunchAgentCommand.xml` to accurately reflect your setup
- Ensure the LaunchAgent specification is properly formatted via `plutil ~/Library/LaunchAgents/com.user.usagemonitormaintenance.plist`
- Add `UsageMonitorMaintenance` as a LaunchAgent script via `launchctl load ~/Library/LaunchAgents/com.user.usagemonitormaintenance.plist` and `launchctl start com.user.usagemonitormaintenance.plist`
- Stop the `UsageMonitorMaintenance` with `launchctl unload ~/Library/LaunchAgents/com.user.usagemonitormaintenance.plist`


## DISCLAIMER: 
WHEN INSTALLED AND GIVEN NECESSARY PERMISSIONS, THIS CODE WILL TRACK USAGE STATISTICS INCLUDING, BUT NOT LIMITED TO, ALL USER KEYSTROKES. THIS DATA IS CURRENTLY USED TO CALCULATE KEY USAGE FREQUENCIES, BUT IT COULD BE CONVERTED INTO A FULL KEYSTROKE LOGGER. THE AUTHOR OF THIS CODE DOES NOT CONDONE ANY SUCH USAGE, AND SHALL NOT BE RESPONSIBLE FOR ANY HARMS RESULTING FROM THE USE OF THIS CODE OR ANY WORK DERIVED FROM THIS CODE.
