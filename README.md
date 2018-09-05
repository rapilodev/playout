# playout
audio playout scheduler

To schedule an audio file for playout put it a directory at /<media_path>/yyyy/mm/dd/hh-mm/.
The first matching file found in a directory will be played at the given time.
The media directory will be frequently scanned for new files.
You can configure media path and further settings at /etc/playout/playout.conf .
It run as service as user playout for either upstart or systemd. 
Logs can be found at /var/log/playout/playout.log and are rotated by /etc/logrotate.d/playout.
By default playout uses cvlc to play first file found in media directory (interface=simple).
Optionally liquidsoap can be used for playout (to stream or soundcard)
In case of unexpected process interruption or system restart the current audio will be played from the current position in time.
The schedule metadata can be uploaded to an given URL for further processing.
There is support for audio streams located in a <name>.stream file containing an URL and a duration.
Optionally the rms package is used to parse exact duration and plot and upload audio RMS plots.