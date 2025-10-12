# MacBook Usage Monitor

## Motivation
The purpose of this code is to Allow one to track various hardward utilization metrics for their MacBook. In particular, this code tracks screen time by logging all sleep/wake and screen lock/unlock events. In addition it tracks battery usage by periodically logging the current battery percentage, the battery health, the current number of charge cycles, and whether the MacBook is currently charging. Finally, the code also tracks keystrokes, storing the frequency of usage for each key.

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
WHEN INSTALLED AND GIVEN NECESSARY PERMISSIONS, THIS CODE WILL TRACK USAGE STATISTICS INCLUDING, BUT NOT LIMITED TO, ALL USER KEYSTROKES. THIS DATA IS CURRENTLY USED TO CALCULATE KEY USAGE FREQUENCIES, IT COULD BE CONVERTED INTO A FULL KEYSTROKE LOGGER. THE AUTHOR OF THIS CODE DOES NOT CONDONE ANY SUCH USAGE, AND SHALL NOT BE RESPONSIBLE FOR ANY HARMS RESULTING FROM THE USE OF THIS CODE OR ANY WORK DERIVED FROM THIS CODE.
