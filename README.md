# MP4 to MKV batch converter
This script was written with the same intent as the [MKVToolNix-missing-ctts-atom-repair](https://github.com/gbballpack/MKVToolNix-missing-ctts-atom-repair/) script. That is, to fix the dreaded [missing ctts atom issue](https://forums.plex.tv/t/example-of-stuttering-hevc-playback-on-apple-tv-4k/558255) that causes effected videos to non-stop stutter when played in Plex. It does this by simply converting MP4 files to MKV files (no re-encoding is done). This script differs from the above mentioned script in that it only uses `mkvmerge` (not ffmpeg, etc) and that it does not convert the file back to an MP4. It can also optionally tag, unmonitor, and refresh the movies in Radarr.

# Requirements
- bash environment (tested successfully on Unraid)
- [MKVTookNix docker](https://github.com/jlesage/docker-mkvtoolnix) (also available in Unraid app store)

# Usage
Make sure that file is executable with `chmod +x mp4_to_mkv.sh` and carefully set all required user variables in the script file. Run it and sit back and watch the progress happen.
