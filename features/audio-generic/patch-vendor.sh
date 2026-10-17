#!/usr/bin/env bash
# Built-in audio on PCs. Googlebook's audio HAL (dras, APEX com.android.hardware.audio.desktop)
# takes its card name and config dir from Google's hardware mapping table, whose default is
# Lenovo's board: dir /vendor/etc/audio/sof-rt5682_alc5682ivs_tas2563, card hw:sofrt5682. No PC
# has that card: after 10 s "Primary module audio will not work" - only USB/Bluetooth audio.
# We add generic configs, one per ALSA card ID, in etc/audio/<id>. At boot get_variant_audio
# finds the PC's card and sets vendor.audio.soundcard.name (the HAL's card-name override) and
# vendor.audio.churro.card; init then bind-mounts etc/audio/<id> over the board dir(s), so the
# HAL reads our config whichever dir it resolves, and restarts the HAL (churro-audio.rc).
# Covered: HD-audio codecs on the legacy driver (snd_hda_intel: "PCH" Intel, "Generic*" AMD,
# "Intel" older Intel/QEMU) and on SOF's generic HDA machine ("sofhdadsp", laptops with DMICs).
# Speaker and headphones share PCM 0 (the kernel's HDA auto-mute switches between them);
# outputs come up unmuted at 0 dB (HDA generic parser), the HAL applies volume in software.
set -euo pipefail
T=$1; A=$T/etc/audio; F=$(dirname "$0"); S=$T/etc/selinux
CFG=u:object_r:vendor_configs_file:s0
boards=(); for d in "$A"/*/; do d=${d%/}; [ -f "$d/audio_config.xml" ] && boards+=("${d##*/}"); done
[ ${#boards[@]} -gt 0 ] || { echo "audio-generic: no board audio config in $A" >&2; exit 1; }

# The card ID the HAL waits for comes from Google's mapping table (not from the config dir), so
# init renames the PC's card to it (ALSA allows that via /sys/class/sound/cardN/id); our configs
# address the card by that name.
W=$(sed -n 's|.*<SoundCardName>hw:\([^<]*\)</SoundCardName>.*|\1|p' "$A/${boards[0]}/audio_config.xml")
[ -n "$W" ] || { echo "audio-generic: no SoundCardName in ${boards[0]}" >&2; exit 1; }
ids=()
# mk <card id> <jack device prefix> <internal mic PCM> [<HDMI PCM>...]
mk() {
  local id=$1 jp=$2 mic=$3 d=$A/$1 n=0 h; shift 3
  mkdir -p "$d"; ids+=("$id")
  { printf '<?xml version="1.0" encoding="utf-8"?>\n<!-- Project Churro audio-generic: ALSA card %s, renamed %s at boot -->\n<audio_config>\n' "$id" "$W"
    printf '\t<SoundCardName>hw:%s</SoundCardName>\n\t<HiFi>\n' "$W"
    # same fields as Google's board config (DSPLatency on every non-HDMI node, mic channel map)
    printf '\t\t<Speaker>\n\t\t\t<PlaybackPCM>hw:%s,0</PlaybackPCM>\n\t\t\t<DSPLatency>0</DSPLatency>\n\t\t</Speaker>\n' "$W"
    printf '\t\t<InternalMic>\n\t\t\t<CapturePCM>hw:%s,%s</CapturePCM>\n' "$W" "$mic"
    printf '\t\t\t<CaptureChannelMap>\n\t\t\t\t<FL>0</FL>\n\t\t\t\t<FR>1</FR>\n\t\t\t</CaptureChannelMap>\n'
    printf '\t\t\t<IntrinsicSensitivity>-2600</IntrinsicSensitivity>\n\t\t\t<DSPLatency>0</DSPLatency>\n\t\t</InternalMic>\n'
    for h; do n=$((n+1))
      printf '\t\t<HDMI%d>\n\t\t\t<PlaybackPCM>hw:%s,%s</PlaybackPCM>\n' $n "$W" "$h"
      printf '\t\t\t<JackDev>%s HDMI/DP,pcm=%s</JackDev>\n\t\t\t<PlaybackChannels>2</PlaybackChannels>\n\t\t</HDMI%d>\n' "$jp" "$h" $n
    done
    printf '\t</HiFi>\n</audio_config>\n'; } > "$d/audio_config.xml"
  { printf '<?xml version="1.0" encoding="utf-8"?>\n<mixer enum_mixer_numeric_fallback="true">\n'
    printf '\t<path name="Speaker" />\n\t<path name="InternalMic" />\n'
    n=0; for h; do n=$((n+1)); printf '\t<path name="HDMI%d" />\n' $n; done
    printf '</mixer>\n'; } > "$d/mixer_paths.xml"
  cp "$A/${boards[0]}/volume_curves.xml" "$d/"
  # Google's DSP graph is neutral (speaker pass-through, DC blocker on the mic)
  [ -f "$A/${boards[0]}/dsp.ini" ] && cp "$A/${boards[0]}/dsp.ini" "$d/"
  find "$d" -exec chown -h root:root {} + -exec setfattr -h -n security.selinux -v "$CFG" {} \;
}
mk PCH "HDA Intel PCH" 0 3 7 8 9
mk Intel "HDA Intel" 0
mk Generic "HD-Audio Generic" 0
mk Generic_1 "HD-Audio Generic" 0
mk sofhdadsp sof-hda-dsp 6 3 4 5   # SOF HDA topology: 0 analog, 3-5 HDMI, 6 DMIC

tr -d '\r' < "$F/get_variant_audio" > "$T/bin/get_variant_audio"   # Windows checkouts: CRLF
chown root:2000 "$T/bin/get_variant_audio"; chmod 0755 "$T/bin/get_variant_audio"
setfattr -n security.selinux -v u:object_r:get_variant_audio_exec:s0 "$T/bin/get_variant_audio"

R=$T/etc/init/churro-audio.rc
{ cat <<'EOF'
# Project Churro audio-generic: generic audio HAL config for the PC's sound card
# (/vendor/bin/get_variant_audio picks it; see features/audio-generic)
service vendor.churro.audio /vendor/bin/get_variant_audio
    class core
    user root
    group root
    oneshot
    disabled

on boot
    start vendor.churro.audio
EOF
  # one trigger per card, literal paths: init expands ${...} in vendor rc files as vendor_init,
  # which may not read vendor.audio.* (the mount itself runs as init)
  for id in "${ids[@]}"; do
    printf '\non property:vendor.audio.churro.card=%s\n' "$id"
    for b in "${boards[@]}"; do echo "    mount none /vendor/etc/audio/$id /vendor/etc/audio/$b bind"; done
    echo "    restart vendor.audio-hal-aidl"
  done
  for n in 0 1 2 3 4 5 6 7; do
    printf '\non property:vendor.audio.churro.index=%s\n    write /sys/class/sound/card%s/id %s\n' $n $n "$W"
  done; } > "$R"
chown root:root "$R"; chmod 0644 "$R"; setfattr -n security.selinux -v "$CFG" "$R"

V=$(cat "$S/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro audio-generic: get_variant_audio reads its configs in /vendor/etc/audio
(allow get_variant_audio vendor_configs_file_$V (dir (search getattr open read)))
(allow get_variant_audio vendor_configs_file_$V (file (getattr open read)))
; churro-audio.rc renames the sound card (write /sys/class/sound/cardN/id runs as vendor_init)
(allow vendor_init_$V sysfs_$V (file (getattr open write)))
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: audio-generic: configs for ${ids[*]} over ${boards[*]}"
