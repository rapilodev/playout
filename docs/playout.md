# PLAYOUT(1)

## NAME

playout - audio playout scheduler

## SYNOPSIS

```
systemctl start|stop|restart|status playout
```

## DESCRIPTION

Playout is an automated audio scheduler that plays audio files at specified times based on directory structure. Files are placed in directories named by date and time, and playout automatically plays them at the scheduled moment.

## DIRECTORY STRUCTURE

Audio files must be placed in directories following this format:

```
<media_path>/YYYY/MM/DD/HH-MM/audio_file.mp3
```

Where:
- **YYYY** - Four-digit year (2025)
- **MM** - Two-digit month (01-12)
- **DD** - Two-digit day (01-31)
- **HH-MM** - Hour and minute in 24-hour format (00-00 to 23-59)

Example:
```
/var/playout/media/2025/12/15/14-30/show.mp3
```

This file will play at 14:30 on December 15, 2025.

## BEHAVIOR

**Playback Rules**
- First file found alphabetically in time slot directory is played
- Playback starts precisely at scheduled time
- Current file stops when next schedule begins
- No audio plays if directory is empty

**File Discovery**
- Media directory scanned continuously
- New files detected automatically
- No service restart required

**Resume on Interruption**
- Service calculates elapsed time on restart
- Resumes playback from current position
- Prevents content repetition or gaps

**Streams**
- Create `.stream` file with URL and DURATION
- Format: `URL: http://example.com/stream.mp3` and `DURATION: 3600`

## INSTALLATION

```bash
dpkg -i playout_<version>.deb
systemctl enable playout
systemctl start playout
```

## CONFIGURATION

Configuration file: `/etc/playout/playout.conf`

**Essential Options:**
```
media_path = /var/playout/media
log_file = /var/log/playout/playout.log
log_level = info
scan_interval = 10
```

**Optional:**
```
upload_enabled = 0|1
upload_url = http://server/api/schedule
rms_enabled = 0|1
```

Apply changes:
```bash
systemctl restart playout
```

## FILES

```
/etc/playout/playout.conf          Configuration file
/var/playout/media/                Media directory
/var/log/playout/playout.log       Log file
/etc/logrotate.d/playout           Log rotation config
```

## SERVICE MANAGEMENT

```bash
systemctl status playout           # Check status
systemctl start playout            # Start service
systemctl stop playout             # Stop service
systemctl restart playout          # Restart service
systemctl enable playout           # Enable autostart
systemctl disable playout          # Disable autostart
```

## MONITORING

View logs:
```bash
tail -f /var/log/playout/playout.log
journalctl -u playout -f
```

Logs contain:
- Playback start/stop events
- File not found warnings
- Resume operations
- Service status changes

## EXAMPLES

**Schedule daily morning show:**
```bash
mkdir -p /var/playout/media/2025/12/15/06-00
cp morning_show.mp3 /var/playout/media/2025/12/15/06-00/
chown -R playout:playout /var/playout/media/2025/12/15
```

**Schedule hourly news:**
```bash
mkdir -p /var/playout/media/2025/12/15/{08-00,09-00,10-00}
cp news.mp3 /var/playout/media/2025/12/15/08-00/
cp news.mp3 /var/playout/media/2025/12/15/09-00/
cp news.mp3 /var/playout/media/2025/12/15/10-00/
```

**Schedule stream:**
```bash
mkdir -p /var/playout/media/2025/12/15/20-00
cat > /var/playout/media/2025/12/15/20-00/concert.stream << EOF
URL: http://radio.example.com/live.mp3
DURATION: 7200
EOF
```

## TROUBLESHOOTING

**Service won't start:**
```bash
systemctl status playout
journalctl -u playout -n 50
```

**File not found:**
- Verify directory structure (YYYY/MM/DD/HH-MM)
- Check system time: `date`
- Verify permissions: `ls -la /var/playout/media/`

**Wrong timing:**
- Check timezone: `timedatectl`
- Sync system clock: `systemctl start systemd-timesyncd`

**Fix permissions:**
```bash
chown -R playout:playout /var/playout/media/
chmod -R 755 /var/playout/media/
```

## SUPPORTED FORMATS

Any format supported by ffmpeg: MP3, WAV, OGG, FLAC, AAC, M4A

## SEE ALSO

systemctl(1), journalctl(1), ffmpeg(1)

## AUTHOR

rapilodev

## REPOSITORY

https://github.com/rapilodev/playout

## LICENSE

GPL-3.0