# playout

Audio Playout Scheduler

To schedule an audio file for playback, place it in a directory under / <media path> / YYYY / MM / DD / HH-MM /. 

The first matching file in a directory is played at the specified time. 

The media directory is frequently searched for new files. 

You can configure the media path and other settings under /etc/playout/playout.conf. 

It runs as a service with a user "playout" for upstart or systemd. 

Logs can be found at /var/log/playout/playout.log and are rotated by /etc/logrotate.d/playout. 

By default, playback uses cvlc to play the first file found in the media directory (interface = simple). 

Optionally, liquidsoap can be used for playback (for streaming or for the sound card). 

In case of unexpected process interruptions or system restarts, the current audio is played from the current position in time. 

The schedule metadata can be uploaded to a specific URL for further processing. 

Audio streams in a .stream file with a URL and duration are supported. 

The RMS package is optionally used to analyze the exact duration and to draw and upload audio RMS diagrams.

