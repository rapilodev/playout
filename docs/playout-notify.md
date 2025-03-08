# PLAYOUT-NOTIFY(1) - User Commands

## NAME
**playout-notify** - Notifies of changes in the radio station's schedule

## SYNOPSIS
`playout-notify`

## DESCRIPTION
The `playout-notify` script automates the process of notifying changes in the radio station's schedule. 
It runs a specified command to generate `schedule.txt`, commits the changes to a Git repository, 
and sends an email notification with the commit details.

## CONFIGURATION
The configuration file `/etc/playout/notify` should include:

```ini
git_repo = /path/to/repo
command = /path/to/command
email:
  from = sender@example.com
  to = recipient@example.com
  subject = "Schedule Update Notification"
```
