#!/bin/bash
set -euo pipefail

# Check for input files
# NOTE: this currently assumes m4a/b audiofiles
if [ $# -lt 1 ]; then
  echo "Usage: $0 <file1.m4a> <file2.m4a> ..."
  exit 1
fi

# Create safe temporary directory
tmpdir=$(mktemp -d -t audiomerge-XXXXXXXXXX)
cleanup_needed=true

# Set conditional trap
# trap '[[ $cleanup_needed == "true" ]] && { echo "Cleaning up"; rm -rf "$tmpdir"; }' EXIT INT TERM

# Initialize arrays
declare -a input_files=("$@")
declare -a durations
declare -a meta_files
declare -a cover_images

process_chapter_info() {
  # Given a list of chapters in json and an offset in milliseconds
  # generate the new ffmetadata chapter information with new offset
  local meta_file="$1"
  local offset="$2"

  local chapter_data
  chapter_data=$(jq -r --argjson offset "$offset" '
        .chapters[] | 
        "[CHAPTER]\n" +
        "TIMEBASE=1/1000\n" +
        "START=\(.start + $offset)\n" +
        "END=\(.end + $offset)\n" +
        "title=\(.tags.title // "Untitled")\n"
    ' "$meta_file")

  printf "%s" "$chapter_data"
}

extract_cover_art() {
  local input_file="$1"
  local output_file="$2"
  ffmpeg -i "$input_file" -an -vcodec copy "$output_file" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "Cover extracted: $output_file"
  else
    echo "No cover found in $input_file"
    return 1
  fi
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
  # NOTE: I am assuming the first file has the correct metadata values and ignoring the rest except chapter info
  for i in "${!input_files[@]}"; do
    file="${input_files[$i]}"
    absolute_path=$(realpath "$file")
    echo "Processing $file..."

    # Create file list (with proper quoting)
    list_file="$tmpdir/list.txt"

    # Populate ffmpeg file list
    # absolute_path="/path/to/file/Author's Notes (Final).m4a"
    printf "file '%s'\n" "${absolute_path}" >>"$list_file"
    # NOTE: Works but doesn't escape single quoets in file path
    # file '/path/to/file/Author's Notes (Final).m4a'

    # This should hopefully escape the single quotes inside of $absolute_path
    # but actually escapes all special charcters
    # printf "file '%q' " "${absolute_path}" >>"$list_file"
    # WARN: escapes all spcial charcters
    # file '/path/to/file/Author\'s\ Notes\ \(Final\).m4a'

    # printf "file '%s'\n" "${absolute_path//'/'\''}" >>"$list_file"
    # WARN: does not create the escaped format cleanup_needed
    # file '/path/to/file/Author\'\\'\'s Notes (Final).m4a'
    # 'This is how you '\''escape'\'' a single quote'

    # printf "file '%q $absolute_path'" >>$list_file

    # Extract metadata
    meta_file="$tmpdir/meta$i.json"
    ffprobe -v quiet -i "$file" -show_chapters -show_format -of json >"$meta_file"
    meta_files+=("$meta_file")

    # Get cover image
    # WARN: assuming jpg for convenience
    cover_image="$tmpdir/cover_$i.jpg"
    if extract_cover_art "$file" "$cover_image"; then
      cover_images+=("$cover_image")
    fi
    # Get original file duration in seconds (floating-point) for precision in file comparison
    duration=$(jq -r '.format.duration' "$meta_file")

    # For integer milliseconds (rounded):
    rounded_ms=$(sec2msInt $duration)
    # echo "Rounded milliseconds: $rounded_ms"

    # process_chapters
    result=$(process_chapter_info "$meta_file" "$cumulative_offset")
    printf "%s" "$result" >>"$chapters_file"

    # set each file offset to running total of duration_ms as integer.
    cumulative_offset=$((cumulative_offset + rounded_ms))

    # Keep total in seconds with full precision and compare later as milliseconds
    durations+=("$duration")
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

create_combined_metafile() {
  # combined_meta="$tmpdir/metafile.txt"
  combined_meta=$(printf "%q" "$tmpdir/metadata.txt")
  # Header and file creation
  echo ";FFMETADATA1" >"$combined_meta"
  # Global Metadata (year does not appear to be supported)
  get_required_tags "$tmpdir/meta0.json" "artist" "album" "album_artist" >>"$combined_meta"

  # [Stream] Metadata placeholder
  # [Chapter] Metadata
  cat "$chapters_file" >>"$combined_meta"
}

merge_audiobooks() {
  # Merge files and apply metadata
  # NOTE: `-movflags use_metadata_tags` doesn't seem to actually keep the global metadata
  # NOTE: testing composing the ffmpeg command in a function

  set -x
  echo "Merging files..."
  # Use an array to store command components
  local ffmpeg_args=()

  # Add base command components
  ffmpeg_args+=(
    -loglevel error
    -hide_banner
    -f concat
    -safe 0
    -i "$list_file" # Escape special chars
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
  # convert seconds to rounded MS integers
  total_ms=$(echo "scale=3; $seconds * 1000" | bc)

  # For integer milliseconds (rounded):
  rounded_ms=$(printf "%.0f" "$total_ms")
  echo "$rounded_ms"
}

get_file_duration_in_ms() {
  local meta_file="$1"
  duration=$(ffprobe -v quiet -i "$meta_file" -show_format -of json | jq -r '.format.duration')
  # duration_ms=$(echo "$duration * 1000" | bc | cut -d. -f1)
  duration_ms=$(sec2msInt $duration)
  echo "$duration_ms"
}

# Verify merged audiobook
verify_merged_file() {
  # compare final cumulative_offset to sum of durations which should be the same as final file duration
  #
  merged_duration=$(get_file_duration_in_ms "$tmpdir/merged.m4a")
  echo "Merged file duration is: $merged_duration"
  expected_duration=0

  # Sum durations using bc (scale=6 for 6 decimal places)
  sum_seconds=$(
    IFS=+
    echo "scale=6; ${durations[*]}" | bc
  )
  echo "Total seconds: $sum_seconds" # Output: 381.457415

  expected_duration_ms=$(sec2msInt $sum_seconds)
  echo "Expected duration was: $expected_duration_ms"

  if [ "$merged_duration" -eq "$expected_duration_ms" ]; then
    echo "Duration verification passed"
  else
    echo "Warning: Merged file duration ($merged_duration ms) does not match sum of input durations ($expected_duration ms)"
    # If failure occurs:
    open "$tmpdir"
    cleanup_needed=false
    return 1
  fi
}

process_input_files
create_combined_metafile
merge_audiobooks
# add_cover_art WARN: adding the cover art works, but apparently removes the artist and album tags from the file... shruggie
verify_merged_file

# Move final file to current directory
final_output="$artist-$album.m4b"
mv "$tmpdir/merged.m4a" "./$final_output"
mv "$combined_meta" .

echo "Successfully created: $final_output"
