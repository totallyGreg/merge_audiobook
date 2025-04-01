#!/bin/bash
set -euo pipefail

# Check for input files
# NOTE: this currently assumes m4a/b audiofiles
if [ $# -lt 1 ]; then
  echo "Usage: $0 <file1.m4a> <file2.m4a> ..."
  exit 1
fi

# # Create safe temporary directory
tmpdir=$(mktemp -d -t audiomerge-XXXXXXXXXX)
output_dir=$(dirname "$1")
cleanup_needed=true

# Set conditional trap
trap '[[ $cleanup_needed == "true" ]] && { echo "Cleaning up"; rm -rf "$tmpdir"; }' EXIT INT TERM

# Initialize file arrays
declare -a valid_files=()
declare -a durations
declare -a meta_files
declare -a cover_images

# Process input arguments (files/directories)
for input in "$@"; do
  if [[ -d "$input" ]]; then
    # Handle directory - process all files in directory
    output_dir=$input
    while IFS= read -r -d $'\0' file; do
      if { file -b --mime-type "$file" | grep -qiE 'audio/(mp4|x-m4a|aac)'; } \
        || [[ "$file" =~ \.(m4a|m4b)$ ]]; then
        aac_files+=("$file")
      fi
    done < <(find "$input" -type f -print0)
    IFS=$'\n' valid_files=($(sort <<<"${aac_files[*]}"))
    unset IFS
  elif [[ -f "$input" ]]; then
    # Handle single file
    valid_files+=("$input")
  else
    echo "Error: '$input' is not a valid file or directory" >&2
    exit 1
  fi
done

# PERF: fairly well organized
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

# Main loop
album=""
artist=""
cumulative_offset=0
chapters_file="$tmpdir/chapters.txt"

# Process each input file
process_input_files() {
  # Create file list (with proper quoting)
  file_list="$tmpdir/list.txt"

  # NOTE: I am assuming the first file has the correct metadata values and ignoring the rest except chapter info
  for i in "${!valid_files[@]}"; do
    file="${valid_files[$i]}"
    absolute_path=$(realpath "$file")
    echo "Processing $file..."

    generate_ffmpeg_file_list() {
      # generate concat demuxer input file line
      # NOTE: replace any single quotes with escaped single quotes https://trac.ffmpeg.org/wiki/Concatenate
      # absolute_path="/path/to/file/Author's Notes (Final).m4a"
      ffmpeg_path=${absolute_path//\'/\'\\\'\'}
      echo "file '${ffmpeg_path}'"
    }
    generate_ffmpeg_file_list >>"$file_list"

    # Extract metadata
    meta_file="$tmpdir/meta$i.json"
    ffprobe -v quiet -i "$file" -show_chapters -show_format -of json >"$meta_file"
    meta_files+=("$meta_file")

    # Get cover image
    # HACK: assuming jpg for convenience
    cover_image="$tmpdir/cover_$i.jpg"
    if extract_cover_art "$file" "$cover_image"; then
      cover_images+=("$cover_image")
    fi

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
}

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

generate_ffmetadata() {
  # combined_meta="$tmpdir/metafile.txt"
  combined_meta=$(printf "%q" "$tmpdir/metadata.txt")
  # Header and file creation
  echo ";FFMETADATA1" >"$combined_meta"
  # Global Metadata (year does not appear to be supported)
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

process_input_files
generate_ffmetadata
merge_m4a_files
# add_cover_art WARN: adding the cover art works, but apparently removes the artist and album tags from the file... shruggie
verify_merged_file

# Move final file to directory # ${output_dir}
final_output="$output_dir/$artist-$album.m4b"
mv "$tmpdir/merged.m4a" "$final_output"
mv "$combined_meta" "$output_dir"
mv "$chapters_file" "$output_dir"

echo "Successfully created: ${final_output}"
