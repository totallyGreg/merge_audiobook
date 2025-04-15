#!/bin/bash
set -euox pipefail

# Check for input files
# NOTE: this currently assumes m4a/b audiofiles
if [ $# -lt 1 ]; then
  echo "Usage: $0 <file1.m4a> <file2.m4a> ..."
  exit 1
fi

# # Create safe temporary directory
tmpdir=$(mktemp -d -t audiomerge-XXXXXXXXXX)
converted_pipe="$tmpdir/converted_file"
mkfifo "$converted_pipe"
# output_dir=$(dirname "$1")
output_dir=$(pwd)
cleanup_needed=false

# Set conditional trap
trap '[[ $cleanup_needed == "true" ]] && { echo "Cleaning up"; rm -rf "$tmpdir"; }' EXIT INT TERM

# Initialize file arrays
declare -a valid_files=()
declare -a durations
declare -a meta_files
declare -a cover_images

convert_mp3_to_m4b() {
  # TODO: need to extract any metadata before converting
  local input_mp3="${1}"
  local output_m4b
  local afconvert_path=$(which afconvert)

  # Check if afconvert is installed
  if [[ -z "${afconvert_path}" ]]; then
    echo "Error: afconvert is not installed.  This script requires macOS." >&2
    return 1 # Indicate failure
  fi

  # Construct output filename (replace .mp3 with .m4b)
  output_m4b="$tmpdir/${input_mp3%.mp3}.m4b"

  # Convert an audiofile to m4b with variable bitrate
  # -s 3 = ABR
  # --soundcheck-generate: Generate soundcheck data for volume normalization
  # -f m4bf: Output format (M4B audiobook)
  # -d aach: MPEG-4 High Efficiency AAC
  # -q 10: Quality level (10 is high)
  # echo "Converting $input_mp3 to $output_m4b..."
  "${afconvert_path}" --media-kind "Audiobook" --soundcheck-generate "${input_mp3}" -s 3 -f m4bf -d aach -q 10 "${output_m4b}"

  # Check the exit code of afconvert
  if [[ $? -ne 0 ]]; then
    echo "Error: afconvert failed to convert $input_mp3 to $output_m4b." >&2
    return 1 # Indicate failure
  fi

  # echo "✅Successfully converted $input_mp3 👉🏽 $output_m4b"
  # echo "$output_m4b" >"$converted_pipe" # Return the output filename
  echo "$output_m4b"
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

# Process list of input files into an audiobook
process_audiobook() {
  # TODO: refactor this to be called directly by process_argument and or process_directory
  # accept list of files as $@ iterate through each using process_file
  # to build up the valid_files list
  album=""
  artist=""
  cumulative_offset=0
  chapters_file="$tmpdir/chapters.txt"

  echo "Begin Processing valid_files array containing ${#valid_files[*]} files"
  # Create file list (with proper quoting)
  file_list="$tmpdir/list.txt"

  # function to generate concat demuxer input file line
  generate_ffmpeg_file_list() {
    # NOTE: replace any single quotes with escaped single quotes https://trac.ffmpeg.org/wiki/Concatenate
    # absolute_path="/path/to/file/Author's Notes (Final).m4a"
    ffmpeg_path=${absolute_path//\'/\'\\\'\'}
    echo "file '${ffmpeg_path}'"
  }

  # HACK: I am assuming the first file has the correct metadata values and ignoring the rest except chapter info
  # NOTE: Main processing loop
  # validates files, converts if necessary, then builds both the ffmpeg_file_list
  # and the FFMETADATA1 with tags, chapters and duration
  for i in "${!valid_files[@]}"; do
    file="${valid_files[$i]}"
    absolute_path=$(realpath "$file")
    echo "Processing $file..."
    # TODO: call process_file here
    # return only valid m4a/m4b files

    generate_ffmpeg_file_list >>"$file_list"

    # Extract metadata
    meta_file="$tmpdir/meta$i.json"
    ffprobe -v quiet -i "$file" -show_chapters -show_format -of json >"$meta_file"
    meta_files+=("$meta_file")

    # Get cover image
    # HACK: assuming jpg for convenience
    # cover_image="$tmpdir/cover_$i.jpg"
    # if extract_cover_art "$file" "$cover_image"; then
    #   cover_images+=("$cover_image")
    # fi

    # Get original file duration in seconds (floating-point) for precision in file comparison
    file_duration=$(jq -r '.format.duration' "$meta_file")

    # For integer milliseconds (rounded):
    rounded_ms=$(sec2msInt $file_duration)

    # process_chapters
    generate_chapter_info "$meta_file" "$cumulative_offset" >>"$chapters_file"

    # set each file offset to running total of duration_ms as integer.
    cumulative_offset=$((cumulative_offset + rounded_ms))

    # Store total file durations in seconds with full precision and compare later as milliseconds
    durations+=("$file_duration")
  done

  generate_ffmetadata
  merge_m4a_files
  # add_cover_art WARN: adding the cover art works, but apparently removes the artist and album tags from the file... shruggie
  verify_merged_file

  # Move final file to directory # ${output_dir}
  # TODO: fix "-.m4b" file being created if no artist/album when trying to cancel
  final_output="$output_dir/$artist-$album.m4b"
  mv "$tmpdir/merged.m4a" "$final_output"
  mv "$combined_meta" "$output_dir"
  mv "$chapters_file" "$output_dir"

  echo "Successfully created: ${final_output}"
}

# processes a file (if supported audio) and builds the valid_files array
process_file() {

  # Constants - avoid magic strings
  AUDIO_MP3="audio/mpeg"
  FILE_MP3=".mp3"
  AUDIO_M4A="audio/x-m4a"
  FILE_M4A=".m4a"
  FILE_M4B=".m4b"

  local file="$1"
  local mime_type
  local aac_file

  mime_type=$(file -b --mime-type "$file")

  if [[ "$mime_type" =~ $AUDIO_M4A ]] || [[ "$file" =~ $FILE_M4A ]] || [[ "$file" =~ $FILE_M4B ]]; then
    echo "Adding M4A file: $file to valid_files array" # Replace with actual processing
    aac_file=("$file")
  elif [[ "$mime_type" =~ $AUDIO_MP3 ]] || [[ "$file" =~ $FILE_MP3 ]]; then
    local converted_file
    echo "Converting MP3: $file to M4B:"
    converted_file=$(convert_mp3_to_m4b "$file")
    # read -r converted_file <converted_pipe
    echo "Adding M4A file: $converted_file to valid_files array" # Replace with actual processing
    aac_file=("$converted_file")
  else
    echo "Skipping file: $file (unsupported type)"
  fi
  valid_files+=("$aac_file")
}

# Process input arguments (files/directories)
process_argument() {
  local arg="$1"

  if [[ -d "$arg" ]]; then
    local dir="$arg"
    output_dir="$dir"

    # Find all files in the directory and send to process_file in sorted order
    # -z: This option tells sort to use null characters (\0) as delimiters.
    # This is essential when dealing with filenames that contain spaces or other special characters.
    # Without -z, sort would misinterpret spaces as delimiters, leading to incorrect sorting.
    find "$dir" -type f -print0 | sort -z | while IFS= read -r -d $'\0' file; do
      process_file "$file"
    done
    # process_directory "$arg"
    # TODO: consider calling process_valid_files for directories here
  elif [[ -f "$arg" ]]; then
    process_file "$arg"
  else
    echo "Error: '$arg' is not a valid file or directory" >&2
    exit 1
  fi
}

for input in "$@"; do
  process_argument "$input"
done

get_required_tags() {
  set -e
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
  combined_meta=$(printf "%q" "$tmpdir/metadata.txt")
  # Header and file creation
  echo ";FFMETADATA1" >"$combined_meta"
  # Global Metadata (year does not appear to be supported)
  # WARN: Currently required tags is being run after mp3 conversion
  # NOTE: currently only parsing first file
  # get_required_tags "$tmpdir/meta0.json" "artist" "album" "album_artist" >>"$combined_meta"
  get_required_tags "$tmpdir/meta0.json" "artist" "album" >>"$combined_meta"

  # [Stream] Metadata placeholder
  # [Chapter] Metadata
  cat "$chapters_file" >>"$combined_meta"
}

merge_m4a_files() {
  # Merge m4a files and apply metadata
  # NOTE: `-movflags use_metadata_tags` doesn't seem to actually keep the global metadata
  # NOTE: testing composing the ffmpeg command in a function

  echo "Merging files..."
  # Use an array to store command components
  local ffmpeg_args=()

  # Add base command components
  ffmpeg_args+=(
    -loglevel error
    -hide_banner
    -f concat
    -safe 0
    -i "$file_list" # Escape special chars
    -i "$(printf "%q" "$combined_meta")"
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
  echo "Expected duration in ms: $expected_duration"

  # Allow for a small margin of error (e.g., 1 second = 1000 ms)
  margin=1000
  difference=$((merged_duration - expected_duration))
  difference_abs=${difference#-} # Remove minus sign if present

  if [ "$difference_abs" -gt "$margin" ]; then
    echo "Warning: Merged file duration ($merged_duration ms) differs significantly from sum of input durations ($expected_duration ms)" >&2
    exit 1
  else
    echo "Duration verification passed: ${difference_abs}ms within $margin ms margin"
  fi
}

process_audiobook
