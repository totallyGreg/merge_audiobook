#!/bin/bash
set -euo pipefail

# Check for input files
# NOTE: this currently assumes m4a/b audiofiles
if [ $# -lt 1 ]; then
  echo "Usage: $0 <file1.m4a> <file2.m4a> ..."
  exit 1
fi

# # Create safe temporary directory
tmpdir=$(mktemp -d -t audiomerge)
# converted_pipe="$tmpdir/converted_file"
# mkfifo "$converted_pipe"
# output_dir=$(dirname "$1")
output_dir=$(pwd)
cleanup_needed=true

ok() { echo -e '\033[1;32m'"$1"'\033[0m'; }
warn() { echo -e '\033[1;33m'"$1"'\033[0m'; }
error() {
  echo -e '\033[1;31mERROR: '"$1"'\033[0m'
  logger "$1"
}

# Set conditional trap
trap '[[ $cleanup_needed == "true" ]] && { ok "Cleaning up"; rm -rf "$tmpdir"; }' EXIT INT TERM

# optimized conversion for any audio type
convert_to_m4b() {
  local input_file="${1}"
  # If not given, construct output filename in tempdir (replace .mp3 with .m4b)
  # local output_file="${2:-${tmpdir}/${input_file%.*}.m4b}"

  local caff_file="${2:-${input_file%.*}.caf}"
  local m4b_file="${2:-${input_file%.*}.m4b}"
  # mkfifo audio_pipe.caf
  # trap 'echo "Cleaning up"; rm audio_pipe.caf' EXIT TERM

  local afconvert_path=$(which afconvert)

  # # Check if afconvert is installed
  if [[ -z "${afconvert_path}" ]]; then
    error "afconvert is not installed.  This script requires macOS." >&2
    return 1 # Indicate failure
  fi
  audio_to_caf "$input_file" "$tmpdir"/"$caff_file"
  output_file=$(caf_to_m4b "$tmpdir"/"$caff_file" "$tmpdir"/"$m4b_file")

  echo "${output_file}"
}

audio_to_caf() {
  # NOTE: experiment to try and take any audio and pass through highest quality
  local input_file=${1}
  local output_file="${2:-${input_file%.*}.caf}"
  # Converts MP3 → CAF (Apple's core audio format)
  # Generates loudness metadata (--soundcheck-generate + --anchor-generate)
  # Preserves original audio quality (-d 0 = no data format conversion)
  afconvert "$input_file" -o "${output_file}" -d 0 -f caff \
    --soundcheck-generate \
    --anchor-generate

  # echo "${output_file}"
}

caf_to_m4b() {
  local input_file=${1}
  local output_file="${2:-${input_file%.caf}.m4b}"
  afconvert -f m4bf -d aac -q 127 -s 3 \
    --soundcheck-read \
    --media-kind "Audiobook" \
    "${input_file}" -o "${output_file}"

  echo "${output_file}"
}

# WARN: Still can't get named pipes to work with afconvert
audio_caf_m4b_pipeline() {
  # NOTE: named pipe experiment to reduce extra flle writing
  local input_file="${1}"
  local caff_file="${2:-${input_file%.*}.caf}"
  local m4b_file="${2:-${input_file%.*}.m4b}"
  # mkfifo audio_pipe.caf
  # trap 'echo "Cleaning up"; rm audio_pipe.caf' EXIT TERM

  audio_to_caf "$input_file" "$tmpdir"/"$caff_file"
  caf_to_m4b "$tmpdir"/"$caff_file" "$tmpdir"/"$m4b_file"

  # WARN: soundcheck information is sent after file in named pipe so fails
  #
  # # Start read pipe for convert in background
  # while IFS= read -r file; do
  #   afconvert <(echo "$file") -f m4bf -d aac -q 127 -s 3 &
  # done &
  #
  # while true; do
  #   afconvert caff.pipe -f m4bf -d aac -q 127 -s 3 &
  # done &

  # --soundcheck-read \

  # # Convert and feed to pipe
  # for file in $input_files; do
  #   afconvert "$file" audio_pipe.caf -d 0 -f caff
  #   # --soundcheck-generate \
  #   # --anchor-generate
  # done
}

# PERF: fairly well organized
# TODO: this should be called recursively but MUST be sorted first
generate_chapter_info() {
  local meta_file="$1"
  local offset="$2"

  # Single JSON parse with type conversion
  local chapter_data
  chapter_data=$(jq -r --argjson offset "$offset" '
    def sec2ms: (. | tonumber) * 1000 | floor;

    (.chapters | length > 0) as $has_chapters |
    (.format.filename // "Untitled" | sub("\\.[^.]+$"; "")) as $filename_base |
    (.format.duration? // "0" | sec2ms) as $duration_ms |
    (.format.start_time? // "0" | sec2ms) as $start_time_ms |

    if $has_chapters then
      .chapters[] |
      "[CHAPTER]\n" +
      "TIMEBASE=1/1000\n" +
      "START=\((.start | tonumber | sec2ms) + $offset)\n" +
      "END=\((.end | tonumber | sec2ms) + $offset)\n" +
      "title=\(.tags.title // $filename_base)\n"
    else
      "[CHAPTER]\n" +
      "TIMEBASE=1/1000\n" +
      "START=\($start_time_ms + $offset)\n" +
      "END=\($start_time_ms + $offset + $duration_ms)\n" +
      "title=\($filename_base)\n"
    end
  ' "$meta_file")

  printf "%s\n" "$chapter_data"
}

extract_cover_art() {
  local input_file="$1"
  local output_file="$2"
  ffmpeg -i "$input_file" -an -vcodec copy "$output_file" 2>/dev/null
  # if [ $? -eq 0 ]; then
  #   echo "Cover extracted: $output_file"
  # else
  #   echo "No cover found in $input_file"
  #   return 1
  # fi
}

add_cover_art() {
  if [ ${#cover_images[@]} -eq 0 ]; then
    echo "No cover images found. Skipping cover art addition."
  else
    mp4art --add "$tmpdir/cover_0.jpg" --preserve "$tmpdir/merged.m4a"
  fi
}

gather_file_info() {
  local input_file="$1"
  # local ffmetadata="$tmpdir/${file}.json"
  # ffmetadata=$(ffprobe -v quiet -i "$input_file" -show_chapters -show_format -of json)
  # ffprobe -v quiet -i "$input_file" -show_chapters -show_format -of json >"$ffmetadata"

  # NOTE: This works but creates extra files
  meta_file="$tmpdir/${file}.json"
  ffprobe -v quiet -i "$file" -show_chapters -show_format -of json >"$meta_file"
  [[ -z $artist ]] && artist=$(jq -r '.format.tags.artist' "$meta_file")
  [[ -z $album ]] && album=$(jq -r '.format.tags.album' "$meta_file")
  [[ -z $year ]] && year=$(jq -r '.format.tags.date' "$meta_file")
  file_duration=$(jq -r '.format.duration' "$meta_file")
  # For integer milliseconds (rounded):
  rounded_ms=$(sec2msInt $file_duration)

  # HACK: trying to save data to variable instead of to file
  # meta_file=$(ffprobe -v quiet -i "$input_file" -show_chapters -show_format -of json)
  # [[ -z ${artist} ]] && artist=$(jq -r '.format.tags.artist' <<<"$meta_data")
  # [[ -z ${album} ]] && album=$(jq -r '.format.tags.album' <<<"$meta_data")
  # [[ -z ${year} ]] && year=$(jq -r '.format.tags.date' <<<"$meta_data")
  #
  # file_duration=$(jq -r '.format.duration' <<<"$meta_file")
  # cat "$ffmetadata"
}

# processes a file (if supported audio) and builds the valid_files array
process_file() {
  local file="$1"
  local mime_type
  local aac_file
  local meta_file

  echo "Processing $file..."
  start_timestamp=$(date +%s)
  # meta_file="$tmpdir/${file}.json"
  mime_type=$(file -b --mime-type "$file")
  if [[ "$mime_type" =~ $AUDIO_M4A ]] || [[ "$file" =~ $FILE_M4A ]] || [[ "$file" =~ $FILE_M4B ]]; then
    # NOTE: just pass m4a/b files on through
    gather_file_info "$file"
    aac_file="$file"
  elif [[ "$mime_type" =~ $AUDIO_MP3 ]] || [[ "$file" =~ $FILE_MP3 ]]; then
    # NOTE: MP3 files are converted to m4b before adding to ffmpeg_file_merge_list
    local converted_file
    gather_file_info "$file"
    echo "Converting MP3: $file to M4B:"
    converted_file=$(convert_to_m4b "$file")
    aac_file="$converted_file"
  else
    warn "Skipping file: $file (unsupported type)"
  fi

  # NOTE: for each valid aac file to merge, generate the ffmpeg file line
  generate_ffmpeg_concat_line "$aac_file"

  # HACK: moved to gather_file_info
  # Get original file duration in seconds (floating-point) for precision in file comparison
  # file_duration=$(jq -r '.format.duration' "$meta_file")

  # NOTE: then generate any chapter information
  generate_chapter_info "$meta_file" "$cumulative_offset" >>"$chapters_file"

  # NOTE: and finally increment offset and storage arrays
  cumulative_offset=$((cumulative_offset + rounded_ms)) # NOTE: set each file offset to running total of duration_ms as integer.
  valid_files+=("$aac_file")
  durations+=("$file_duration") # NOTE: Store total file durations in seconds with full precision and compare later as milliseconds
  meta_files+=("$meta_file")    # NOTE: Store meta data file location in array

  # end_timestamp=$(date +%s)
  # elapsed_time=$(expr $end_timestamp - $start_timestamp) # WARN: this seems to stop processing of the function
  # echo "Elapsed: $elapsed_time seconds"
}

# Process list of input files into an audiobook
process_audiobook() {
  # Given 1 or more files including a directory
  # Process the file with the minimum required tags into an m4b audiobok file

  # Constants - avoid magic strings
  AUDIO_MP3="audio/mpeg"
  FILE_MP3=".mp3"
  AUDIO_M4A="audio/x-m4a"
  FILE_M4A=".m4a"
  FILE_M4B=".m4b"

  # Initialize file arrays
  declare -a valid_files=()
  declare -a durations
  declare -a meta_files
  declare -a cover_images

  album=""
  artist=""
  year=""
  cumulative_offset=0

  # Create file list (with proper quoting)
  file_merge_list="$tmpdir/file_merge_list.txt"
  chapters_file="$tmpdir/chapters.txt"

  # function to generate concat demuxer input file line
  generate_ffmpeg_concat_line() {
    # NOTE: replace any single quotes with escaped single quotes https://trac.ffmpeg.org/wiki/Concatenate
    # absolute_path="/path/to/file/Author's Notes (Final).m4a"
    local input_file="$1"
    absolute_path=$(realpath "$input_file")
    ffmpeg_path=${absolute_path//\'/\'\\\'\'}
    echo "file '${ffmpeg_path}'" >>"$file_merge_list"
  }

  # NOTE: Main processing loop
  # validates list files, converts if necessary, then builds both the ffmpeg_file_list
  # and the FFMETADATA1 with tags, chapters and duration
  local arg="$@"

  warn "Argument: $arg received"
  for arg; do
    if [[ -d "$arg" ]]; then
      local dir="$arg"
      output_dir="$dir"
      pushd "$dir"

      # Find all files in the directory and send to process_file in sorted order
      # -z: This option tells sort to use null characters (\0) as delimiters.
      # This is essential when dealing with filenames that contain spaces or other special characters.
      # Without -z, sort would misinterpret spaces as delimiters, leading to incorrect sorting.
      # find "$dir" -type f -print0 | sort -z | while IFS= read -r -d $'\0' file; do
      #   process_file "$file"
      # done
      for f in *.mp3; do
        process_file "$f"
      done
      popd

    elif [[ -f "$arg" ]]; then
      process_file "$arg"
    else
      error "'$arg' is not a valid file or directory" >&2
      exit 1
    fi
  done

  # Get cover image
  # HACK: assuming jpg for convenience
  # cover_image="$tmpdir/cover_$i.jpg"
  # if extract_cover_art "$file" "$cover_image"; then
  #   cover_images+=("$cover_image")
  # fi

  merge_m4a_files
  # add_cover_art WARN: adding the cover art works, but apparently removes the artist and album tags from the file... shruggie
  verify_merged_file

  # NOTE: Move final file to directory # ${output_dir}
  # TODO: fix "-.m4b" file being created if no artist/album when trying to cancel
  final_output="$output_dir/$artist-$album.m4b"
  mv "$tmpdir/merged.m4a" "$final_output"
  mv "$ffmetadata" "$output_dir"
  mv "$chapters_file" "$output_dir"

  ok "Successfully created: ${final_output}"
}

get_required_tags() {
  # NOTE: when passed a list of required tags will attempt to set from metadata
  # OR prompt user to input prior to merging of audiobook
  local json_file="$1"
  shift
  local required_tags=("$@")

  # NOTE: eval is setting a variable for each tag that can be used later (i.e. artist)
  for tag in "${required_tags[@]}"; do
    value=$(jq -r ".format.tags.$tag // empty" "$json_file")
    if [ -n "$value" ]; then
      eval "${tag}=\"$value\""
      echo "$tag=${!tag}"
    else
      read -p "Enter value for $tag: " new_value
      eval "${tag}=\"$new_value\""
      echo "$tag=${!tag}"
    fi
  done
}

# Generate required ffmpeg metadata file
generate_ffmetadata() {
  # combined_meta="$tmpdir/metafile.txt"
  ffmetadata=$(printf "%q" "$tmpdir/ffmetadata.txt")
  # Header and file creation
  echo ";FFMETADATA1" >"$ffmetadata"
  # Global Metadata (year does not appear to be supported)
  # NOTE: currently only parsing first file
  if [[ -n $artist ]]; then
    echo "artist=$artist" >>$ffmetadata
    echo "album=$album" >>$ffmetadata
  else
    get_required_tags "${meta_files[0]}" "artist" "album" >>"$ffmetadata"
  fi
  # [Stream] Metadata placeholder
  # [Chapter] Metadata
  cat "$chapters_file" >>"$ffmetadata"
}

# Merge m4a files with metadata
merge_m4a_files() {
  # requires file merge list created by `generate_ffmpeg_file_merge_list`
  # and required tags and chapters created with generate_ffmetadata
  generate_ffmetadata

  # NOTE: `-movflags use_metadata_tags` doesn't seem to actually keep the global metadata
  # NOTE: testing composing the ffmpeg command in a function

  echo "==========================================="
  echo "Merging $(cat $file_merge_list | wc -l) files..."
  # Use an array to store command components
  local ffmpeg_args=()

  # Add base command components
  ffmpeg_args+=(
    -loglevel error
    -hide_banner
    -f concat
    -safe 0
    -i "$file_merge_list" # Escape special chars
    -i "$(printf "%q" "$ffmetadata")"
  )

  # Add mapping and encoding options
  ffmpeg_args+=(
    -map_metadata 1
    -map_chapters 1
    -map 0:a
    -movflags use_metadata_tags
    -c copy
    "$(printf "%q" "$tmpdir/merged.m4a")" # Escape output path
  )

  # for cover in "${cover_images[@]}"; do
  #   ffmpeg_args+=(-i "$cover" )
  # done

  # Execute with proper quoting
  ffmpeg "${ffmpeg_args[@]}"
}

sec2msInt() {
  local seconds=$1
  # convert real number seconds to milliseconds
  total_ms=$(echo "scale=3; $seconds * 1000" | bc)

  # convert to integer milliseconds (rounded):
  rounded_ms=$(printf "%.0f" "$total_ms")
  echo "$rounded_ms"
}

get_file_duration_in_ms() {
  local file="$1"
  file_duration=$(ffprobe -v quiet -i "$file" -show_format -of json | jq -r '.format.duration')
  duration_ms=$(sec2msInt $file_duration)
  echo "$duration_ms"
}

# Verify merged audiobook
verify_merged_file() {
  # compare final cumulative_offset to sum of durations which should be the same as final file duration
  #
  merged_duration=$(get_file_duration_in_ms "$tmpdir/merged.m4a")
  if [ $? -ne 0 ] || [ -z "$merged_duration" ] || [ "$merged_duration" -eq 0 ]; then
    echo "Error: Failed to get valid duration for merged file" >&2
    exit 1
  fi
  # merged_duration=$(get_file_duration_in_ms "$tmpdir/merged.m4a")
  expected_duration=0

  # Sum durations using bc (scale=6 for 6 decimal places)
  sum_seconds=$(
    IFS=+
    echo "scale=6; ${durations[*]}" | bc
  )
  echo "Total seconds of all files: $sum_seconds" # Output: 381.457415
  echo "Merged file duration in ms: $merged_duration"

  expected_duration=$(sec2msInt $sum_seconds)
  warn "Expected duration in ms: $expected_duration"

  # Allow for a small margin of error (e.g., 1 second = 1000 ms)
  margin=1000
  difference=$((merged_duration - expected_duration))
  difference_abs=${difference#-} # Remove minus sign if present

  if [ "$difference_abs" -gt "$margin" ]; then
    warn "Warning: Merged file duration ($merged_duration ms) differs significantly from sum of input durations ($expected_duration ms)" >&2
    exit 1
  else
    ok "Duration verification passed: ${difference_abs}ms within $margin ms margin"
  fi
}

# If first argument matches a function name, use it; otherwise default to process_audiobook
if declare -f "$1" >/dev/null; then
  func="$1"
  shift # Remove function name from arguments
  "$func" "$@"
else
  # Default to process_audiobook with all arguments
  process_audiobook "$@"
fi
